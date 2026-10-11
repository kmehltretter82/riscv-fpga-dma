`timescale 1ns/1ps

// Linux boot and interrupt-driven DMAengine test for the locked Cheshire RTL.
//
// This is deliberately separate from the randomized bare-metal campaign.  It
// boots the same OpenSBI payload that can be loaded on a Cheshire FPGA build,
// observes Linux through the real UART, and independently proves that iDMA
// requests reached the RTL frontend and AXI backend.
module tb_cheshire_linux_dma_irq;

  `include "cheshire/typedef.svh"

  import cheshire_pkg::*;

  localparam time ClockPeriod    = 20ns;  // OpenSBI and DT describe 50 MHz.
  localparam time RtcHalfPeriod  = 500ns; // 1 MHz timebase.
  // Divisor 2 at 50 MHz gives an exact 1.5625 Mbaud.  The locked OBI UART
  // rejects divisor 1 after converting it to its internal divisor-minus-one
  // representation, so divisor 2 is its fastest usable setting.  Keeping the
  // real UART in the path still cuts serialized console time substantially.
  localparam time UartBaudPeriod = 1s / 1_562_500;
  localparam string PassToken    = "FPGA-LINUX-DMA-IRQ-PASS";
  localparam int unsigned PassTokenLen = 23;

  function automatic cheshire_cfg_t gen_linux_cfg();
    cheshire_cfg_t ret = DefaultCfg;

    // This simulation preloads OpenSBI directly at PlatformRom.  Use
    // Cheshire's documented no-Bootrom direct-entry path so the 32-bit
    // PlatformRom parameter is zero-extended into the CVA6 reset vector.
    // The Bootrom path instead reads its optional external ROM address with
    // RV64 `lw`, which sign-extends 0x8000_0000 and is unsuitable for using
    // DRAM itself as that optional ROM.
    ret.Bootrom       = 0;
    ret.PlatformRom   = 32'h8000_0000;
    ret.RtcFreq       = 1_000_000;
    ret.LlcNotBypass  = 1;
    ret.LlcOutConnect = 1;

    // Linux needs the UART and the system iDMA.  Disable unrelated blocks to
    // reduce elaboration and simulation cost without changing those paths.
    ret.Uart       = 1;
    ret.Dma        = 1;
    ret.I2c        = 0;
    ret.SpiHost    = 0;
    ret.Gpio       = 0;
    ret.SerialLink = 0;
    ret.Vga        = 0;
    ret.Usb        = 0;
    ret.AxiRt      = 0;
    ret.Clic       = 0;
    ret.IrqRouter  = 0;
    ret.BusErr     = 1;

    // Route 0x40000000 to a real AXI SLVERR target.  The 0x50000000
    // aperture remains unmapped and is handled by the crossbar DECERR port.
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
  longint unsigned dma_busy_cycles;
  longint unsigned dma_issue_count;
  longint unsigned dma_retire_count;
  longint unsigned dma_ar_count;
  longint unsigned dma_aw_count;
  longint unsigned dma_r_beat_count;
  longint unsigned dma_w_beat_count;
  longint unsigned dma_b_count;
  longint unsigned mem_ar_count;
  longint unsigned mem_r_beat_count;
  longint unsigned mem_aw_count;
  longint unsigned mem_w_beat_count;
  longint unsigned mem_b_count;
  longint unsigned pc_transition_count;
  longint unsigned exception_count;
  longint unsigned dcache_flush_count;
  longint unsigned dcache_flush_ack_count;
  longint unsigned backend_rsp_count;
  longint unsigned backend_error_rsp_count;
  longint unsigned abort_action_count;
  longint unsigned read_slverr_count;
  longint unsigned write_slverr_count;
  longint unsigned read_decerr_count;
  longint unsigned write_decerr_count;
  longint unsigned buserr_push_count;
  longint unsigned buserr_pop_count;
  longint unsigned buserr_full_cycles;
  longint unsigned completion_irq_cycles;
  longint unsigned completion_irq_rises;
  longint unsigned completion_irq_acks;
  longint unsigned error_irq_rises;
  longint unsigned software_abort_accepts;
  longint unsigned post_abort_terminal_writes;
  logic [31:0]     initial_next_id;
  logic [31:0]     initial_done_id;
  logic            id_snapshot_taken;
  logic            previous_read_irq;
  logic            previous_write_irq;
  logic            previous_read_pop;
  logic            previous_write_pop;
  logic [63:0]     previous_commit_pc;
  logic            previous_bist_done;
  logic            platform_fetch_seen;
  logic            kernel_fetch_seen;
  logic [15:0]     previous_uart_divisor;
  logic            previous_dcache_flush;
  logic            previous_completion_irq;
  logic            previous_error_irq;
  logic            software_abort_inflight;
  logic            after_abort_terminal;

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
  ) i_slverr (
    .clk_i      ( clk ),
    .rst_ni     ( rst_n ),
    .test_i     ( 1'b0 ),
    .slv_req_i  ( fault_req[0] ),
    .slv_resp_o ( fault_rsp[0] )
  );

  // Sparse, byte-addressed simulation memory stands in for an FPGA board's
  // external DRAM.  The synthesizable LLC and its AXI path remain in circuit.
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

  always @(posedge clk) begin
    if (!rst_n) begin
      cycle_count      <= 0;
      dma_busy_cycles  <= 0;
      dma_issue_count  <= 0;
      dma_retire_count <= 0;
      dma_ar_count     <= 0;
      dma_aw_count     <= 0;
      dma_r_beat_count <= 0;
      dma_w_beat_count <= 0;
      dma_b_count      <= 0;
      mem_ar_count     <= 0;
      mem_r_beat_count <= 0;
      mem_aw_count     <= 0;
      mem_w_beat_count <= 0;
      mem_b_count      <= 0;
      pc_transition_count <= 0;
      exception_count     <= 0;
      dcache_flush_count  <= 0;
      dcache_flush_ack_count <= 0;
      backend_rsp_count <= 0;
      backend_error_rsp_count <= 0;
      abort_action_count <= 0;
      read_slverr_count <= 0;
      write_slverr_count <= 0;
      read_decerr_count <= 0;
      write_decerr_count <= 0;
      buserr_push_count <= 0;
      buserr_pop_count <= 0;
      buserr_full_cycles <= 0;
      completion_irq_cycles <= 0;
      completion_irq_rises <= 0;
      completion_irq_acks <= 0;
      error_irq_rises <= 0;
      software_abort_accepts <= 0;
      post_abort_terminal_writes <= 0;
      initial_next_id <= 0;
      initial_done_id <= 0;
      id_snapshot_taken <= 0;
      previous_read_irq <= 0;
      previous_write_irq <= 0;
      previous_read_pop <= 0;
      previous_write_pop <= 0;
      previous_commit_pc  <= 0;
      previous_bist_done  <= 0;
      platform_fetch_seen <= 0;
      kernel_fetch_seen   <= 0;
      previous_uart_divisor <= 16'hffff;
      previous_dcache_flush <= 0;
      previous_completion_irq <= 0;
      previous_error_irq <= 0;
      software_abort_inflight <= 0;
      after_abort_terminal <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      previous_bist_done <=
        i_dut.gen_llc.i_llc.i_axi_llc_top_raw.i_hit_miss_unit.i_tag_store
          .i_tag_pattern_gen.eoc_q;
      previous_commit_pc <=
        i_dut.gen_cva6_cores[0].i_core_cva6.pc_commit;
      previous_dcache_flush <=
        i_dut.gen_cva6_cores[0].i_core_cva6.dcache_flush_ctrl_cache;
      previous_completion_irq <=
        i_dut.gen_dma.i_idma.completion_irq_o;
      previous_error_irq <= i_dut.intr.intn.dma_error;

      if (i_dut.gen_dma.i_idma.completion_irq_o)
        completion_irq_cycles <= completion_irq_cycles + 1;
      if (i_dut.gen_dma.i_idma.completion_irq_o &&
          !previous_completion_irq)
        completion_irq_rises <= completion_irq_rises + 1;
      if (i_dut.gen_dma.i_idma.done_id_read &&
          i_dut.gen_dma.i_idma.completion_irq_o)
        completion_irq_acks <= completion_irq_acks + 1;
      if (i_dut.intr.intn.dma_error && !previous_error_irq)
        error_irq_rises <= error_irq_rises + 1;
      if (i_dut.gen_dma.i_idma.sw_abort_accepted) begin
        software_abort_accepts <= software_abort_accepts + 1;
        software_abort_inflight <= 1'b1;
      end
      if (software_abort_inflight && i_dut.gen_dma.i_idma.retire_id) begin
        software_abort_inflight <= 1'b0;
        after_abort_terminal <= 1'b1;
      end
      if (after_abort_terminal && i_dut.gen_dma.i_idma.issue_id)
        after_abort_terminal <= 1'b0;
      if (after_abort_terminal && !i_dut.gen_dma.i_idma.issue_id &&
          i_dut.gen_dma.i_idma.axi_write_req.w_valid &&
          i_dut.gen_dma.i_idma.axi_write_rsp.w_ready)
        post_abort_terminal_writes <= post_abort_terminal_writes + 1;
      previous_read_irq <=
        i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.err_irq_o[1];
      previous_write_irq <=
        i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.err_irq_o[0];
      previous_read_pop <=
        i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.i_read_err_unit
          .i_err_unit_bare.pop_err_fifo;
      previous_write_pop <=
        i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.i_write_err_unit
          .i_err_unit_bare.pop_err_fifo;

      if (!id_snapshot_taken) begin
        initial_next_id <= i_dut.gen_dma.i_idma.next_id;
        initial_done_id <= i_dut.gen_dma.i_idma.done_id;
        id_snapshot_taken <= 1'b1;
      end

      if (previous_read_irq &&
          !i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.err_irq_o[1] &&
          !previous_read_pop)
        $fatal(1, "DMA read-error IRQ fell without an ERR_CODE pop");
      if (previous_write_irq &&
          !i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.err_irq_o[0] &&
          !previous_write_pop)
        $fatal(1, "DMA write-error IRQ fell without an ERR_CODE pop");

      if (!previous_dcache_flush &&
          i_dut.gen_cva6_cores[0].i_core_cva6.dcache_flush_ctrl_cache) begin
        dcache_flush_count <= dcache_flush_count + 1;
        if (dcache_flush_count < 32)
          $display("[TB] D-cache flush request=%0d cycle=%0d",
                   dcache_flush_count + 1, cycle_count + 1);
      end
      if (i_dut.gen_cva6_cores[0].i_core_cva6.dcache_flush_ack_cache_ctrl)
        dcache_flush_ack_count <= dcache_flush_ack_count + 1;

      if (!previous_bist_done &&
          i_dut.gen_llc.i_llc.i_axi_llc_top_raw.i_hit_miss_unit.i_tag_store
            .i_tag_pattern_gen.eoc_q)
        $display("[TB] LLC BIST complete at cycle=%0d", cycle_count + 1);

      if (i_dut.gen_cva6_cores[0].i_core_cva6.pc_commit !=
          previous_commit_pc) begin
        pc_transition_count <= pc_transition_count + 1;
        if (pc_transition_count < 200)
          $display("[TB] commit transition=%0d cycle=%0d pc=0x%016x",
                   pc_transition_count + 1, cycle_count + 1,
                   i_dut.gen_cva6_cores[0].i_core_cva6.pc_commit);
      end

      if (i_dut.gen_cva6_cores[0].i_core_cva6.ex_commit.valid) begin
        exception_count <= exception_count + 1;
        if (exception_count < 20)
          $display("[TB] exception=%0d cycle=%0d pc=0x%016x cause=0x%0x tval=0x%016x trap_vector=0x%016x",
                   exception_count + 1, cycle_count + 1,
                   i_dut.gen_cva6_cores[0].i_core_cva6.pc_commit,
                   i_dut.gen_cva6_cores[0].i_core_cva6.ex_commit.cause,
                   i_dut.gen_cva6_cores[0].i_core_cva6.ex_commit.tval,
                   i_dut.gen_cva6_cores[0].i_core_cva6.trap_vector_base_commit_pcgen);
      end

      if (!platform_fetch_seen &&
          i_dut.gen_cva6_cores[0].i_core_cva6.i_frontend.npc_q >=
            64'h0000_0000_8000_0000) begin
        platform_fetch_seen <= 1;
        $display("[TB] first platform-ROM fetch at cycle=%0d next_pc=0x%016x",
                 cycle_count + 1,
                 i_dut.gen_cva6_cores[0].i_core_cva6.i_frontend.npc_q);
      end
      if (!kernel_fetch_seen &&
          i_dut.gen_cva6_cores[0].i_core_cva6.i_frontend.npc_q >=
            64'h0000_0000_8020_0000) begin
        kernel_fetch_seen <= 1;
        $display("[TB] first Linux-payload fetch at cycle=%0d next_pc=0x%016x",
                 cycle_count + 1,
                 i_dut.gen_cva6_cores[0].i_core_cva6.i_frontend.npc_q);
      end

      previous_uart_divisor <=
        i_dut.gen_uart.i_uart.i_apb_uart_wrap.i_obi_uart.i_uart_baudgen.divisor;
      if (i_dut.gen_uart.i_uart.i_apb_uart_wrap.i_obi_uart.i_uart_baudgen.divisor !=
          previous_uart_divisor)
        $display("[TB] UART divisor-minus-one changed at cycle=%0d: 0x%04x",
                 cycle_count + 1,
                 i_dut.gen_uart.i_uart.i_apb_uart_wrap.i_obi_uart.i_uart_baudgen.divisor);
      if (|i_dut.gen_dma.i_idma.busy)
        dma_busy_cycles <= dma_busy_cycles + 1;
      if (i_dut.gen_dma.i_idma.issue_id) begin
        dma_issue_count <= dma_issue_count + 1;
        $display("[TB] iDMA issue=%0d cycle=%0d dcache_flushes=%0d/%0d",
                 dma_issue_count + 1, cycle_count + 1,
                 dcache_flush_count, dcache_flush_ack_count);
      end
      if (i_dut.gen_dma.i_idma.retire_id) begin
        if (dma_retire_count == 57 && buserr_push_count < 1)
          $fatal(1, "read-SLVERR job retired before its BusErr record");
        if (dma_retire_count == 59 && buserr_push_count < 2)
          $fatal(1, "write-SLVERR job retired before its BusErr record");
        if (dma_retire_count == 61 && buserr_push_count < 3)
          $fatal(1, "read-DECERR job retired before its BusErr record");
        if (dma_retire_count == 63 && buserr_push_count < 4)
          $fatal(1, "write-DECERR job retired before its BusErr record");
        dma_retire_count <= dma_retire_count + 1;
      end

      if (i_dut.gen_dma.i_idma.idma_rsp_valid &&
          i_dut.gen_dma.i_idma.idma_rsp_ready) begin
        backend_rsp_count <= backend_rsp_count + 1;
        if (i_dut.gen_dma.i_idma.idma_rsp.error)
          backend_error_rsp_count <= backend_error_rsp_count + 1;
      end
      if (i_dut.gen_dma.i_idma.idma_eh_req_valid &&
          i_dut.gen_dma.i_idma.idma_eh_req_ready)
        abort_action_count <= abort_action_count + 1;
      if (i_dut.gen_dma.i_idma.axi_read_req.ar_valid &&
          i_dut.gen_dma.i_idma.axi_read_rsp.ar_ready)
        dma_ar_count <= dma_ar_count + 1;
      if (i_dut.gen_dma.i_idma.axi_write_req.aw_valid &&
          i_dut.gen_dma.i_idma.axi_write_rsp.aw_ready)
        dma_aw_count <= dma_aw_count + 1;
      if (i_dut.gen_dma.i_idma.axi_read_rsp.r_valid &&
          i_dut.gen_dma.i_idma.axi_read_req.r_ready) begin
        dma_r_beat_count <= dma_r_beat_count + 1;
        if (i_dut.gen_dma.i_idma.axi_read_rsp.r.resp == axi_pkg::RESP_SLVERR)
          read_slverr_count <= read_slverr_count + 1;
        if (i_dut.gen_dma.i_idma.axi_read_rsp.r.resp == axi_pkg::RESP_DECERR)
          read_decerr_count <= read_decerr_count + 1;
      end
      if (i_dut.gen_dma.i_idma.axi_write_req.w_valid &&
          i_dut.gen_dma.i_idma.axi_write_rsp.w_ready)
        dma_w_beat_count <= dma_w_beat_count + 1;
      if (i_dut.gen_dma.i_idma.axi_write_rsp.b_valid &&
          i_dut.gen_dma.i_idma.axi_write_req.b_ready) begin
        dma_b_count <= dma_b_count + 1;
        if (i_dut.gen_dma.i_idma.axi_write_rsp.b.resp == axi_pkg::RESP_SLVERR)
          write_slverr_count <= write_slverr_count + 1;
        if (i_dut.gen_dma.i_idma.axi_write_rsp.b.resp == axi_pkg::RESP_DECERR)
          write_decerr_count <= write_decerr_count + 1;
      end

      if (i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.i_read_err_unit
            .i_err_unit_bare.push_err_fifo)
        buserr_push_count <= buserr_push_count + 1;
      if (i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.i_write_err_unit
            .i_err_unit_bare.push_err_fifo)
        buserr_push_count <= buserr_push_count + 1;
      if (i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.i_read_err_unit
            .i_err_unit_bare.pop_err_fifo)
        buserr_pop_count <= buserr_pop_count + 1;
      if (i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.i_write_err_unit
            .i_err_unit_bare.pop_err_fifo)
        buserr_pop_count <= buserr_pop_count + 1;
      if (i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.i_read_err_unit
            .i_err_unit_bare.bus_unit_full ||
          i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.i_write_err_unit
            .i_err_unit_bare.bus_unit_full)
        buserr_full_cycles <= buserr_full_cycles + 1;
      if (llc_req.ar_valid && llc_rsp.ar_ready)
        mem_ar_count <= mem_ar_count + 1;
      if (llc_rsp.r_valid && llc_req.r_ready)
        mem_r_beat_count <= mem_r_beat_count + 1;
      if (llc_req.aw_valid && llc_rsp.aw_ready)
        mem_aw_count <= mem_aw_count + 1;
      if (llc_req.w_valid && llc_rsp.w_ready)
        mem_w_beat_count <= mem_w_beat_count + 1;
      if (llc_rsp.b_valid && llc_req.b_ready)
        mem_b_count <= mem_b_count + 1;

      if (cycle_count == 0 || cycle_count == 9 || cycle_count == 99 ||
          cycle_count == 999 || cycle_count == 9_999 ||
          cycle_count == 99_999 || cycle_count == 999_999 ||
          (cycle_count > 999_999 && cycle_count % 1_000_000 == 999_999))
        $display("[TB] heartbeat cycles=%0d commit_pc=0x%016x next_pc=0x%016x llc_ar/r=%0d/%0d llc_aw/w/b=%0d/%0d/%0d",
                 cycle_count + 1,
                 i_dut.gen_cva6_cores[0].i_core_cva6.pc_commit,
                 i_dut.gen_cva6_cores[0].i_core_cva6.i_frontend.npc_q,
                 mem_ar_count, mem_r_beat_count, mem_aw_count,
                 mem_w_beat_count, mem_b_count);
    end
  end

  task automatic uart_read_byte(output byte bite);
    @(negedge uart_tx);
    #(UartBaudPeriod / 2);
    for (int i = 0; i < 8; i++) begin
      #UartBaudPeriod bite[i] = uart_tx;
    end
    #UartBaudPeriod;
  endtask

  initial begin : uart_monitor
    byte bite;
    int unsigned pass_pos = 0;

    wait (rst_n);
    forever begin
      uart_read_byte(bite);
      $write("%c", bite);
      if (bite == PassToken[pass_pos]) begin
        pass_pos++;
      end else begin
        pass_pos = (bite == PassToken[0]) ? 1 : 0;
      end
      if (pass_pos == PassTokenLen) begin
        if (dma_issue_count != 67 || dma_retire_count != 67)
          $fatal(1, "Linux PASS token but iDMA jobs were issue=%0d retire=%0d",
                 dma_issue_count, dma_retire_count);
        if (dma_busy_cycles == 0 || dma_ar_count == 0 || dma_aw_count == 0 ||
            dma_r_beat_count == 0 || dma_w_beat_count == 0 || dma_b_count == 0)
          $fatal(1, "Linux PASS token without complete iDMA AXI activity");
        if (backend_rsp_count != 71 || backend_error_rsp_count != 4 ||
            abort_action_count != 5)
          $fatal(1,
            "backend error protocol mismatch: responses=%0d errors=%0d aborts=%0d",
            backend_rsp_count, backend_error_rsp_count, abort_action_count);
        if (read_slverr_count != 1 || write_slverr_count != 1 ||
            read_decerr_count != 1 || write_decerr_count != 1)
          $fatal(1,
            "AXI response mismatch: read SLVERR/DECERR=%0d/%0d write=%0d/%0d",
            read_slverr_count, read_decerr_count,
            write_slverr_count, write_decerr_count);
        if (buserr_push_count != 4 || buserr_pop_count != 4 ||
            buserr_full_cycles != 0 ||
            i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.err_irq_o != 2'b00)
          $fatal(1,
            "BusErr mismatch: push=%0d pop=%0d full_cycles=%0d irq=%b",
            buserr_push_count, buserr_pop_count, buserr_full_cycles,
            i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.err_irq_o);
        if ((i_dut.gen_dma.i_idma.next_id - initial_next_id) != 67 ||
            (i_dut.gen_dma.i_idma.done_id - initial_done_id) != 67 ||
            |i_dut.gen_dma.i_idma.busy)
          $fatal(1,
            "iDMA terminal state mismatch: NEXT %0d->%0d DONE %0d->%0d busy=%b",
            initial_next_id, i_dut.gen_dma.i_idma.next_id,
            initial_done_id, i_dut.gen_dma.i_idma.done_id,
            i_dut.gen_dma.i_idma.busy);
        if (dcache_flush_count != 216 ||
            dcache_flush_ack_count != dcache_flush_count)
          $fatal(1,
            "Linux PASS token without balanced cache operations: %0d/%0d",
            dcache_flush_count, dcache_flush_ack_count);
        if (completion_irq_rises != 67 || completion_irq_acks != 67 ||
            completion_irq_cycles < 67 || error_irq_rises != 4 ||
            software_abort_accepts != 1 ||
            post_abort_terminal_writes != 0 ||
            i_dut.gen_dma.i_idma.abort_protocol_error_q ||
            i_dut.gen_dma.i_idma.abort_noop_q ||
            i_dut.gen_dma.i_idma.sw_abort_pending ||
            i_dut.gen_dma.i_idma.completion_irq_o ||
            i_dut.intr.intn.dma_error)
          $fatal(1,
            "IRQ/abort mismatch: completion cycles/rises/acks=%0d/%0d/%0d error_rises=%0d sw_abort=%0d post_terminal_writes=%0d protocol=%0d noop=%0d pending=%0d lines=%0d/%0d",
            completion_irq_cycles, completion_irq_rises,
            completion_irq_acks, error_irq_rises,
            software_abort_accepts, post_abort_terminal_writes,
            i_dut.gen_dma.i_idma.abort_protocol_error_q,
            i_dut.gen_dma.i_idma.abort_noop_q,
            i_dut.gen_dma.i_idma.sw_abort_pending,
            i_dut.gen_dma.i_idma.completion_irq_o,
            i_dut.intr.intn.dma_error);
        $display("\n[TB] FPGA-LINUX-DMA-IRQ-PASS cycles=%0d", cycle_count);
        $display("[TB] iDMA jobs=%0d/%0d busy=%0d ar=%0d aw=%0d r=%0d w=%0d b=%0d",
                 dma_issue_count, dma_retire_count, dma_busy_cycles,
                 dma_ar_count, dma_aw_count, dma_r_beat_count,
                 dma_w_beat_count, dma_b_count);
        $display("[TB] error protocol responses=%0d errors=%0d aborts=%0d read_slverr=%0d write_slverr=%0d read_decerr=%0d write_decerr=%0d",
                 backend_rsp_count, backend_error_rsp_count,
                 abort_action_count, read_slverr_count, write_slverr_count,
                 read_decerr_count, write_decerr_count);
        $display("[TB] BusErr pushes=%0d pops=%0d full_cycles=%0d irq=%b",
                 buserr_push_count, buserr_pop_count, buserr_full_cycles,
                 i_dut.gen_dma.gen_dma_bus_err.i_dma_bus_err.err_irq_o);
        $display("[TB] IDs next_delta=%0d done_delta=%0d busy=%b",
                 i_dut.gen_dma.i_idma.next_id - initial_next_id,
                 i_dut.gen_dma.i_idma.done_id - initial_done_id,
                 i_dut.gen_dma.i_idma.busy);
        $display("[TB] CVA6 D-cache flushes=%0d acknowledgements=%0d",
                 dcache_flush_count, dcache_flush_ack_count);
        $display("[TB] IRQ completion cycles/rises/acks=%0d/%0d/%0d error_rises=%0d software_abort=%0d post_terminal_writes=%0d",
                 completion_irq_cycles, completion_irq_rises,
                 completion_irq_acks, error_irq_rises,
                 software_abort_accepts, post_abort_terminal_writes);
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
      max_cycles = 50_000_000;
    if (LinuxCva6Cfg.DCacheType != config_pkg::WB ||
        !LinuxCva6Cfg.DcacheFlushOnFence ||
        !ariane_pkg::INVALIDATE_ON_FLUSH)
      $fatal(1, "CVA6 cache contract is not WB writeback+invalidate on FENCE");
    $display("[TB] cache contract: legacy WB, FENCE writes back and invalidates");
    $display("[TB] loading OpenSBI+Linux payload: %s", firmware);
    $readmemh(firmware, i_mem.mem);
    $display("[TB] payload load complete; waiting 20 clocks before reset release");
    repeat (20) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    $display("[TB] reset released");
    repeat (max_cycles) @(posedge clk);
    $fatal(1,
      "timeout after %0d cycles; iDMA jobs=%0d/%0d busy=%0d",
      max_cycles, dma_issue_count, dma_retire_count, dma_busy_cycles);
  end

endmodule
