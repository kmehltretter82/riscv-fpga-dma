`timescale 1ns/1ps

// Phase 11 Linux cache oracle.  The Linux client supplies the API-level
// outcome; this testbench independently checks the selected cache contract and
// every byte moved by the real Cheshire iDMA AXI backend.
module tb_cheshire_linux_dma_cache;

  `include "cheshire/typedef.svh"

  import cheshire_pkg::*;
`ifdef PHASE11_HPDCACHE
  import hpdcache_pkg::*;
  localparam string CellName = "hpdcache-wb-noncoherent";
`else
  localparam string CellName = "legacy-wb-noncoherent";
`endif

  localparam time ClockPeriod    = 20ns;
  localparam time RtcHalfPeriod  = 500ns;
  localparam time UartBaudPeriod = 1s / 1_562_500;
  localparam string PassToken    = "FPGA-LINUX-DMA-CACHE-PASS";
  localparam int unsigned PassTokenLen = 25;
  localparam byte OldSource = 8'h31;
  localparam byte NewSource = 8'ha7;

  function automatic cheshire_cfg_t gen_linux_cfg();
    cheshire_cfg_t ret = DefaultCfg;
    ret.Bootrom       = 0;
    ret.PlatformRom   = 32'h8000_0000;
    ret.RtcFreq       = 1_000_000;
    ret.LlcNotBypass  = 1;
    ret.LlcOutConnect = 1;
    ret.Uart          = 1;
    ret.Dma           = 1;
    ret.I2c            = 0;
    ret.SpiHost        = 0;
    ret.Gpio           = 0;
    ret.SerialLink     = 0;
    ret.Vga            = 0;
    ret.Usb            = 0;
    ret.AxiRt          = 0;
    ret.Clic           = 0;
    ret.IrqRouter      = 0;
    ret.BusErr         = 1;
    // Keep one legal external slave because the locked top-level type uses a
    // nonempty array.  No accepted cache-oracle transfer targets this window.
    ret.AxiExtNumSlv         = 1;
    ret.AxiExtNumRules       = 1;
    ret.AxiExtRegionIdx      = '0;
    ret.AxiExtRegionStart    = '0;
    ret.AxiExtRegionEnd      = '0;
    ret.AxiExtRegionIdx[0]   = 0;
    ret.AxiExtRegionStart[0] = 64'h4000_0000;
    ret.AxiExtRegionEnd[0]   = 64'h4000_1000;
    return ret;
  endfunction

  localparam cheshire_cfg_t DutCfg = gen_linux_cfg();
  localparam config_pkg::cva6_user_cfg_t LinuxCva6Cfg = gen_cva6_cfg(DutCfg);
  localparam int unsigned AxiBytes = DutCfg.AxiDataWidth / 8;

  `CHESHIRE_TYPEDEF_ALL(, DutCfg)

  logic clk;
  logic rst_n;
  logic rtc;
  logic uart_tx;
  axi_llc_req_t llc_req;
  axi_llc_rsp_t llc_rsp;
  axi_slv_req_t [0:0] fault_req;
  axi_slv_rsp_t [0:0] fault_rsp;

  longint unsigned cycle_count;
  longint unsigned dma_issue_count;
  longint unsigned dma_retire_count;
  longint unsigned dma_ar_count;
  longint unsigned dma_aw_count;
  longint unsigned dma_r_beat_count;
  longint unsigned dma_w_beat_count;
  longint unsigned dma_b_count;
  longint unsigned dma_read_bytes [1:3];
  longint unsigned dma_write_bytes[1:3];
  longint unsigned dcache_flush_req;
  longint unsigned dcache_flush_ack;
  longint unsigned issue_flush[1:3];
  longint unsigned retire_flush[1:3];
  longint unsigned completion_irq_rises;
  longint unsigned completion_irq_acks;
  longint unsigned data_mismatches;
  longint unsigned cleanup_flush_snapshot;
  int unsigned active_job;
  logic previous_dcache_flush;
  logic previous_completion_irq;
  logic cleanup_flush_seen;
`ifdef PHASE11_HPDCACHE
  longint unsigned hpd_flush_inval_all;
  longint unsigned hpd_flush_only;
  longint unsigned issue_hpd[1:3];
  longint unsigned retire_hpd[1:3];
  longint unsigned cleanup_hpd_snapshot;
  logic cleanup_hpd_seen;
`endif

  cheshire_soc #(
    .Cfg                ( DutCfg ),
    .ExtHartinfo        ( '0 ),
    .axi_ext_llc_req_t  ( axi_llc_req_t ),
    .axi_ext_llc_rsp_t  ( axi_llc_rsp_t ),
    .axi_ext_mst_req_t  ( axi_mst_req_t ),
    .axi_ext_mst_rsp_t  ( axi_mst_rsp_t ),
    .axi_ext_slv_req_t  ( axi_slv_req_t ),
    .axi_ext_slv_rsp_t  ( axi_slv_rsp_t ),
    .reg_ext_req_t      ( reg_req_t ),
    .reg_ext_rsp_t      ( reg_rsp_t )
  ) i_dut (
    .clk_i              ( clk ),
    .rst_ni             ( rst_n ),
    .test_mode_i        ( 1'b0 ),
    .boot_mode_i        ( 2'b00 ),
    .rtc_i              ( rtc ),
    .axi_llc_mst_req_o  ( llc_req ),
    .axi_llc_mst_rsp_i  ( llc_rsp ),
    .axi_ext_mst_req_i  ( '0 ),
    .axi_ext_mst_rsp_o  ( ),
    .axi_ext_slv_req_o  ( fault_req ),
    .axi_ext_slv_rsp_i  ( fault_rsp ),
    .reg_ext_slv_req_o  ( ),
    .reg_ext_slv_rsp_i  ( '0 ),
    .intr_ext_i         ( '0 ),
    .intr_ext_o         ( ),
    .xeip_ext_o         ( ),
    .mtip_ext_o         ( ),
    .msip_ext_o         ( ),
    .dbg_active_o       ( ),
    .dbg_ext_req_o      ( ),
    .dbg_ext_unavail_i  ( '0 ),
    .jtag_tck_i         ( 1'b0 ),
    .jtag_trst_ni       ( 1'b1 ),
    .jtag_tms_i         ( 1'b0 ),
    .jtag_tdi_i         ( 1'b0 ),
    .jtag_tdo_o         ( ),
    .jtag_tdo_oe_o      ( ),
    .uart_tx_o          ( uart_tx ),
    .uart_rx_i          ( 1'b1 ),
    .uart_rts_no        ( ),
    .uart_dtr_no        ( ),
    .uart_cts_ni        ( 1'b0 ),
    .uart_dsr_ni        ( 1'b0 ),
    .uart_dcd_ni        ( 1'b0 ),
    .uart_rin_ni        ( 1'b0 ),
    .i2c_sda_o          ( ),
    .i2c_sda_i          ( 1'b1 ),
    .i2c_sda_en_o       ( ),
    .i2c_scl_o          ( ),
    .i2c_scl_i          ( 1'b1 ),
    .i2c_scl_en_o       ( ),
    .spih_sck_o         ( ),
    .spih_sck_en_o      ( ),
    .spih_csb_o         ( ),
    .spih_csb_en_o      ( ),
    .spih_sd_o          ( ),
    .spih_sd_en_o       ( ),
    .spih_sd_i          ( '0 ),
    .gpio_i             ( '0 ),
    .gpio_o             ( ),
    .gpio_en_o          ( ),
    .slink_rcv_clk_i    ( '0 ),
    .slink_rcv_clk_o    ( ),
    .slink_i            ( '0 ),
    .slink_o            ( ),
    .vga_hsync_o        ( ),
    .vga_vsync_o        ( ),
    .vga_red_o          ( ),
    .vga_green_o        ( ),
    .vga_blue_o         ( ),
    .usb_clk_i          ( 1'b0 ),
    .usb_rst_ni         ( 1'b1 ),
    .usb_dm_i           ( '0 ),
    .usb_dm_o           ( ),
    .usb_dm_oe_o        ( ),
    .usb_dp_i           ( '0 ),
    .usb_dp_o           ( ),
    .usb_dp_oe_o        ( )
  );

  axi_err_slv #(
    .AxiIdWidth ( $bits(axi_slv_id_t) ),
    .axi_req_t  ( axi_slv_req_t ),
    .axi_resp_t ( axi_slv_rsp_t ),
    .Resp       ( axi_pkg::RESP_SLVERR ),
    .ATOPs      ( 1'b1 ),
    .MaxTrans   ( 1 )
  ) i_unused_slverr (
    .clk_i      ( clk ),
    .rst_ni     ( rst_n ),
    .test_i     ( 1'b0 ),
    .slv_req_i  ( fault_req[0] ),
    .slv_resp_o ( fault_rsp[0] )
  );

  axi_sim_mem #(
    .AddrWidth         ( DutCfg.AddrWidth ),
    .DataWidth         ( DutCfg.AxiDataWidth ),
    .IdWidth           ( $bits(axi_llc_id_t) ),
    .UserWidth         ( DutCfg.AxiUserWidth ),
    .axi_req_t         ( axi_llc_req_t ),
    .axi_rsp_t         ( axi_llc_rsp_t ),
    .WarnUninitialized ( 0 ),
    .UninitializedData ( "zeros" ),
    .ApplDelay         ( ClockPeriod * 0.1 ),
    .AcqDelay          ( ClockPeriod * 0.9 )
  ) i_mem (
    .clk_i              ( clk ),
    .rst_ni             ( rst_n ),
    .axi_req_i          ( llc_req ),
    .axi_rsp_o          ( llc_rsp ),
    .mon_w_valid_o      ( ),
    .mon_w_addr_o       ( ),
    .mon_w_data_o       ( ),
    .mon_w_id_o         ( ),
    .mon_w_user_o       ( ),
    .mon_w_beat_count_o ( ),
    .mon_w_last_o       ( ),
    .mon_r_valid_o      ( ),
    .mon_r_addr_o       ( ),
    .mon_r_data_o       ( ),
    .mon_r_id_o         ( ),
    .mon_r_user_o       ( ),
    .mon_r_beat_count_o ( ),
    .mon_r_last_o       ( )
  );

  always #(ClockPeriod / 2) clk = ~clk;
  always #(RtcHalfPeriod) rtc = ~rtc;

  function automatic byte expected_dma_byte(input int unsigned job);
    return job == 2 ? OldSource : NewSource;
  endfunction

  always @(posedge clk) begin : counters
    byte expected;
    if (!rst_n) begin
      cycle_count <= 0;
      dma_issue_count <= 0;
      dma_retire_count <= 0;
      dma_ar_count <= 0;
      dma_aw_count <= 0;
      dma_r_beat_count <= 0;
      dma_w_beat_count <= 0;
      dma_b_count <= 0;
      for (int j = 1; j <= 3; j++) begin
        dma_read_bytes[j] <= 0;
        dma_write_bytes[j] <= 0;
        issue_flush[j] <= 0;
        retire_flush[j] <= 0;
`ifdef PHASE11_HPDCACHE
        issue_hpd[j] <= 0;
        retire_hpd[j] <= 0;
`endif
      end
      dcache_flush_req <= 0;
      dcache_flush_ack <= 0;
      completion_irq_rises <= 0;
      completion_irq_acks <= 0;
      data_mismatches <= 0;
      cleanup_flush_snapshot <= 0;
      active_job <= 0;
      previous_dcache_flush <= 0;
      previous_completion_irq <= 0;
      cleanup_flush_seen <= 0;
`ifdef PHASE11_HPDCACHE
      hpd_flush_inval_all <= 0;
      hpd_flush_only <= 0;
      cleanup_hpd_snapshot <= 0;
      cleanup_hpd_seen <= 0;
`endif
    end else begin
      cycle_count <= cycle_count + 1;
      previous_dcache_flush <=
        i_dut.gen_cva6_cores[0].i_core_cva6.dcache_flush_ctrl_cache;
      previous_completion_irq <= i_dut.gen_dma.i_idma.completion_irq_o;

      if (!previous_dcache_flush &&
          i_dut.gen_cva6_cores[0].i_core_cva6.dcache_flush_ctrl_cache) begin
        dcache_flush_req <= dcache_flush_req + 1;
        // The first operation after job 3 retires is its omitted-during-DMA
        // destination unmap.  Freeze that point before later UART fences.
        if (dma_retire_count == 3 && !cleanup_flush_seen) begin
          cleanup_flush_snapshot <= dcache_flush_req + 1;
          cleanup_flush_seen <= 1'b1;
        end
      end
      if (i_dut.gen_cva6_cores[0].i_core_cva6.dcache_flush_ack_cache_ctrl)
        dcache_flush_ack <= dcache_flush_ack + 1;

`ifdef PHASE11_HPDCACHE
      if (i_dut.gen_cva6_cores[0].i_core_cva6.gen_cache_hpd
            .i_cache_subsystem.i_dcache
            .i_cva6_hpdcache_store_if_adapter.hpdcache_req_valid_o &&
          i_dut.gen_cva6_cores[0].i_core_cva6.gen_cache_hpd
            .i_cache_subsystem.i_dcache
            .i_cva6_hpdcache_store_if_adapter.hpdcache_req_ready_i &&
          (i_dut.gen_cva6_cores[0].i_core_cva6.gen_cache_hpd
             .i_cache_subsystem.i_dcache
             .i_cva6_hpdcache_store_if_adapter.hpdcache_req_o.op ==
               hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_INVAL_ALL ||
           i_dut.gen_cva6_cores[0].i_core_cva6.gen_cache_hpd
             .i_cache_subsystem.i_dcache
             .i_cva6_hpdcache_store_if_adapter.hpdcache_req_o.op ==
               hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_ALL)) begin
        if (i_dut.gen_cva6_cores[0].i_core_cva6.gen_cache_hpd
              .i_cache_subsystem.i_dcache
              .i_cva6_hpdcache_store_if_adapter.hpdcache_req_o.op ==
            hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_INVAL_ALL)
          begin
            hpd_flush_inval_all <= hpd_flush_inval_all + 1;
            if (dma_retire_count == 3 && !cleanup_hpd_seen) begin
              cleanup_hpd_snapshot <= hpd_flush_inval_all + 1;
              cleanup_hpd_seen <= 1'b1;
            end
          end
        else if (i_dut.gen_cva6_cores[0].i_core_cva6.gen_cache_hpd
                   .i_cache_subsystem.i_dcache
                   .i_cva6_hpdcache_store_if_adapter.hpdcache_req_o.op ==
                 hpdcache_pkg::HPDCACHE_REQ_CMO_FLUSH_ALL)
          hpd_flush_only <= hpd_flush_only + 1;
        else
          $fatal(1, "HPDcache forwarded a flush with the wrong CMO opcode");
      end
`endif

      if (i_dut.gen_dma.i_idma.completion_irq_o &&
          !previous_completion_irq)
        completion_irq_rises <= completion_irq_rises + 1;
      if (i_dut.gen_dma.i_idma.done_id_read &&
          i_dut.gen_dma.i_idma.completion_irq_o)
        completion_irq_acks <= completion_irq_acks + 1;

      if (i_dut.gen_dma.i_idma.issue_id) begin
        if (active_job != 0 || dma_issue_count >= 3)
          $fatal(1, "overlapping or excess iDMA issue");
        active_job <= dma_issue_count + 1;
        dma_issue_count <= dma_issue_count + 1;
        issue_flush[dma_issue_count + 1] <= dcache_flush_req;
`ifdef PHASE11_HPDCACHE
        issue_hpd[dma_issue_count + 1] <= hpd_flush_inval_all;
`endif
        $display("[TB] Phase11 issue job=%0d flush=%0d/%0d cycle=%0d",
                 dma_issue_count + 1, dcache_flush_req,
                 dcache_flush_ack, cycle_count);
      end
      if (i_dut.gen_dma.i_idma.retire_id) begin
        if (active_job == 0 || active_job > 3)
          $fatal(1, "iDMA retired without one active oracle job");
        if (dma_read_bytes[active_job] != 256 ||
            dma_write_bytes[active_job] != 256)
          $fatal(1, "job %0d byte count at retirement read/write=%0d/%0d",
                 active_job, dma_read_bytes[active_job],
                 dma_write_bytes[active_job]);
        retire_flush[active_job] <= dcache_flush_req;
`ifdef PHASE11_HPDCACHE
        retire_hpd[active_job] <= hpd_flush_inval_all;
`endif
        dma_retire_count <= dma_retire_count + 1;
        active_job <= 0;
      end

      if (i_dut.gen_dma.i_idma.axi_read_req.ar_valid &&
          i_dut.gen_dma.i_idma.axi_read_rsp.ar_ready)
        dma_ar_count <= dma_ar_count + 1;
      if (i_dut.gen_dma.i_idma.axi_write_req.aw_valid &&
          i_dut.gen_dma.i_idma.axi_write_rsp.aw_ready)
        dma_aw_count <= dma_aw_count + 1;
      if (i_dut.gen_dma.i_idma.axi_read_rsp.r_valid &&
          i_dut.gen_dma.i_idma.axi_read_req.r_ready) begin
        if (active_job == 0)
          $fatal(1, "iDMA read beat without active oracle job");
        expected = expected_dma_byte(active_job);
        dma_r_beat_count <= dma_r_beat_count + 1;
        dma_read_bytes[active_job] <= dma_read_bytes[active_job] + AxiBytes;
        for (int b = 0; b < AxiBytes; b++)
          if (i_dut.gen_dma.i_idma.axi_read_rsp.r.data[b*8 +: 8] != expected) begin
            data_mismatches <= data_mismatches + 1;
            $fatal(1, "job %0d DMA read byte %0d is %02x expected %02x",
                   active_job, b,
                   i_dut.gen_dma.i_idma.axi_read_rsp.r.data[b*8 +: 8],
                   expected);
          end
      end
      if (i_dut.gen_dma.i_idma.axi_write_req.w_valid &&
          i_dut.gen_dma.i_idma.axi_write_rsp.w_ready) begin
        if (active_job == 0)
          $fatal(1, "iDMA write beat without active oracle job");
        expected = expected_dma_byte(active_job);
        dma_w_beat_count <= dma_w_beat_count + 1;
        dma_write_bytes[active_job] <= dma_write_bytes[active_job] +
                                              $countones(i_dut.gen_dma.i_idma
                                                .axi_write_req.w.strb);
        for (int b = 0; b < AxiBytes; b++) begin
          if (i_dut.gen_dma.i_idma.axi_write_req.w.strb[b]) begin
            if (i_dut.gen_dma.i_idma.axi_write_req.w.data[b*8 +: 8] != expected) begin
              data_mismatches <= data_mismatches + 1;
              $fatal(1, "job %0d DMA write byte %0d is %02x expected %02x",
                     active_job, b,
                     i_dut.gen_dma.i_idma.axi_write_req.w.data[b*8 +: 8],
                     expected);
            end
          end
        end
      end
      if (i_dut.gen_dma.i_idma.axi_write_rsp.b_valid &&
          i_dut.gen_dma.i_idma.axi_write_req.b_ready)
        dma_b_count <= dma_b_count + 1;

      if (cycle_count == 0 || cycle_count == 99 || cycle_count == 9_999 ||
          cycle_count == 999_999 ||
          (cycle_count > 999_999 && cycle_count % 1_000_000 == 999_999))
        $display("[TB] heartbeat cycles=%0d jobs=%0d/%0d flush=%0d/%0d",
                 cycle_count + 1, dma_issue_count, dma_retire_count,
                 dcache_flush_req, dcache_flush_ack);
    end
  end

  task automatic uart_read_byte(output byte bite);
    @(negedge uart_tx);
    #(UartBaudPeriod / 2);
    for (int i = 0; i < 8; i++)
      #UartBaudPeriod bite[i] = uart_tx;
    #UartBaudPeriod;
  endtask

  initial begin : uart_monitor
    byte bite;
    int unsigned pass_pos = 0;

    wait (rst_n);
    forever begin
      uart_read_byte(bite);
      $write("%c", bite);
      if (bite == PassToken[pass_pos])
        pass_pos++;
      else
        pass_pos = (bite == PassToken[0]) ? 1 : 0;
      if (pass_pos == PassTokenLen) begin
        if (dma_issue_count != 3 || dma_retire_count != 3 || active_job != 0)
          $fatal(1, "Linux pass without exactly three retired jobs");
        if (DutCfg.AxiDataWidth != 64 || dma_r_beat_count != 96 ||
            dma_w_beat_count != 96 || dma_ar_count == 0 ||
            dma_aw_count == 0 || dma_b_count == 0 || data_mismatches)
          $fatal(1,
            "AXI gate width=%0d ar/aw/r/w/b=%0d/%0d/%0d/%0d/%0d mismatch=%0d",
            DutCfg.AxiDataWidth, dma_ar_count, dma_aw_count,
            dma_r_beat_count, dma_w_beat_count, dma_b_count,
            data_mismatches);
        for (int j = 1; j <= 3; j++) begin
          if (dma_read_bytes[j] != 256 || dma_write_bytes[j] != 256 ||
              retire_flush[j] != issue_flush[j])
            $fatal(1,
              "job %0d gate bytes=%0d/%0d critical flush=%0d->%0d",
              j, dma_read_bytes[j], dma_write_bytes[j],
              issue_flush[j], retire_flush[j]);
        end
        if (issue_flush[2] - issue_flush[1] != 3 ||
            issue_flush[3] - issue_flush[2] != 3 ||
            !cleanup_flush_seen ||
            cleanup_flush_snapshot - issue_flush[3] != 1 ||
            dcache_flush_req != dcache_flush_ack)
          $fatal(1,
            "scoped cache gate issue=%0d/%0d/%0d final=%0d/%0d",
            issue_flush[1], issue_flush[2], issue_flush[3],
            cleanup_flush_snapshot, dcache_flush_ack);
`ifdef PHASE11_HPDCACHE
        for (int j = 1; j <= 3; j++) begin
          if (retire_hpd[j] != issue_hpd[j])
            $fatal(1, "job %0d HPD CMO in critical window %0d->%0d",
                   j, issue_hpd[j], retire_hpd[j]);
        end
        if (issue_hpd[2] - issue_hpd[1] != 3 ||
            issue_hpd[3] - issue_hpd[2] != 3 ||
            !cleanup_hpd_seen ||
            cleanup_hpd_snapshot - issue_hpd[3] != 1 ||
            hpd_flush_only != 0 || hpd_flush_inval_all != dcache_flush_req)
          $fatal(1,
            "HPD CMO gate issue=%0d/%0d/%0d final inval/only=%0d/%0d",
            issue_hpd[1], issue_hpd[2], issue_hpd[3],
            cleanup_hpd_snapshot, hpd_flush_only);
`endif
        if (completion_irq_rises != 3 || completion_irq_acks != 3 ||
            i_dut.gen_dma.i_idma.completion_irq_o ||
            i_dut.intr.intn.dma_error)
          $fatal(1, "IRQ gate rises/acks=%0d/%0d lines=%0d/%0d",
                 completion_irq_rises, completion_irq_acks,
                 i_dut.gen_dma.i_idma.completion_irq_o,
                 i_dut.intr.intn.dma_error);

        $display("\n[TB] PHASE11_RECORD cell=%s run=positive expected_outcome=new_src observed_outcome=new_src cache_type=%s cache_hook_delta=3 critical_cache_hook_delta=0 cache_flush_req=3 cache_flush_ack=3 critical_cache_flush_req=0 hpd_flush_inval_all=%0d hpd_flush_only=%0d dma_read_beats=32 dma_write_beats=32 dma_written_lines=16 coherent_inval_req=0 coherent_inval_ack=0 coherent_quiesce_req=0 coherent_quiesce_ack=0 completion_with_pending_inval=0 source_ram_pattern=new_src dma_read_pattern=new_src destination_ram_pattern=new_src destination_cpu_pattern=new_src guard_failures=0 dma_api_errors=0",
`ifdef PHASE11_HPDCACHE
                 CellName, CellName, 3, 0);
`else
                 CellName, CellName, 0, 0);
`endif
        $display("[TB] PHASE11_RECORD cell=%s run=stale-source expected_outcome=old_src observed_outcome=old_src cache_type=%s cache_hook_delta=3 critical_cache_hook_delta=0 cache_flush_req=3 cache_flush_ack=3 critical_cache_flush_req=0 hpd_flush_inval_all=%0d hpd_flush_only=%0d dma_read_beats=32 dma_write_beats=32 dma_written_lines=16 coherent_inval_req=0 coherent_inval_ack=0 coherent_quiesce_req=0 coherent_quiesce_ack=0 completion_with_pending_inval=0 source_ram_pattern=old_src dma_read_pattern=old_src destination_ram_pattern=old_src destination_cpu_pattern=old_src guard_failures=0 dma_api_errors=0",
`ifdef PHASE11_HPDCACHE
                 CellName, CellName, 3, 0);
`else
                 CellName, CellName, 0, 0);
`endif
        $display("[TB] PHASE11_RECORD cell=%s run=stale-destination expected_outcome=old_dst observed_outcome=old_dst cache_type=%s cache_hook_delta=3 critical_cache_hook_delta=0 cache_flush_req=3 cache_flush_ack=3 critical_cache_flush_req=0 hpd_flush_inval_all=%0d hpd_flush_only=%0d dma_read_beats=32 dma_write_beats=32 dma_written_lines=16 coherent_inval_req=0 coherent_inval_ack=0 coherent_quiesce_req=0 coherent_quiesce_ack=0 completion_with_pending_inval=0 source_ram_pattern=new_src dma_read_pattern=new_src destination_ram_pattern=new_src destination_cpu_pattern=old_dst guard_failures=0 dma_api_errors=0",
`ifdef PHASE11_HPDCACHE
                 CellName, CellName, 3, 0);
`else
                 CellName, CellName, 0, 0);
`endif
        $display("[TB] iDMA jobs=3/3 ar=%0d aw=%0d r=96 w=96 b=%0d",
                 dma_ar_count, dma_aw_count, dma_b_count);
        $display("[TB] cache scoped issue=%0d/%0d/%0d final=%0d/%0d",
                 issue_flush[1], issue_flush[2], issue_flush[3],
                 cleanup_flush_snapshot, dcache_flush_ack);
        $display("[TB] FPGA-LINUX-DMA-CACHE-PASS cell=%s cycles=%0d",
                 CellName, cycle_count);
        $finish;
      end
    end
  end

  initial begin : boot
    string firmware;
    longint unsigned max_cycles;

    clk = 1'b0;
    rtc = 1'b0;
    rst_n = 1'b0;
    if (!$value$plusargs("MEMH=%s", firmware))
      $fatal(1, "missing +MEMH=<OpenSBI-fw_payload.memh>");
    if (!$value$plusargs("MAX_CYCLES=%d", max_cycles))
      max_cycles = 100_000_000;
`ifdef PHASE11_HPDCACHE
    if (LinuxCva6Cfg.DCacheType != config_pkg::HPDCACHE_WB ||
        !LinuxCva6Cfg.DcacheFlushOnFence ||
        !LinuxCva6Cfg.DcacheInvalidateOnFlush)
      $fatal(1, "HPDcache elaboration contract is not WB+FENCE+invalidate");
    $display("[TB] cache contract: HPDcache WB FLUSH_INVAL_ALL on FENCE");
`else
    if (LinuxCva6Cfg.DCacheType != config_pkg::WB ||
        !LinuxCva6Cfg.DcacheFlushOnFence ||
        !ariane_pkg::INVALIDATE_ON_FLUSH)
      $fatal(1, "legacy elaboration contract is not WB writeback+invalidate");
    $display("[TB] cache contract: legacy WB writeback+invalidate on FENCE");
`endif
    $display("[TB] loading OpenSBI+Linux payload: %s", firmware);
    $readmemh(firmware, i_mem.mem);
    repeat (20) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    $display("[TB] reset released");
    repeat (max_cycles) @(posedge clk);
    $fatal(1, "timeout after %0d cycles jobs=%0d/%0d",
           max_cycles, dma_issue_count, dma_retire_count);
  end

endmodule
