`timescale 1ns/1ps

module tb_cheshire_dma_error;

  `include "cheshire/typedef.svh"

  import cheshire_pkg::*;

  localparam time ClockPeriod = 10ns;
  localparam logic [47:0] ModeAddr       = 48'h0000_4000_ffe0;
  localparam logic [47:0] CompletionAddr = 48'h0000_4000_fff8;
  localparam logic [63:0] CompletionMagic = 64'h4552_5244_0000_0000;
  localparam logic [47:0] FirstSrc = 48'h0000_4000_1000;
  localparam logic [47:0] FirstDst = 48'h0000_4000_3000;
  localparam int unsigned FirstLen = 4097;
  localparam int unsigned ExpectedJobs = 2;
  localparam int unsigned ExpectedDoneId = 1 + ExpectedJobs;
  localparam int unsigned ExpectedNextId = 2 + ExpectedJobs;

  localparam int unsigned ModeClean = 0;
  localparam int unsigned ModeExpectContinue = 1;
  localparam int unsigned ModeExpectAbort = 2;
  localparam int unsigned ModeExpectAbortAllowFull = 3;

  function automatic cheshire_cfg_t gen_test_cfg();
    cheshire_cfg_t ret = DefaultCfg;

    ret.Bootrom       = 0;
    ret.PlatformRom   = 32'h2000_0000;
    ret.LlcNotBypass  = 0;
    ret.LlcOutConnect = 0;
    ret.AxiExtNumSlv  = 1;
    ret.AxiExtNumRules = 2;
    ret.AxiExtRegionIdx = '0;
    ret.AxiExtRegionStart = '0;
    ret.AxiExtRegionEnd = '0;
    ret.AxiExtRegionIdx[0] = 0;
    ret.AxiExtRegionStart[0] = 64'h2000_0000;
    ret.AxiExtRegionEnd[0] = 64'h2001_0000;
    ret.AxiExtRegionIdx[1] = 0;
    ret.AxiExtRegionStart[1] = 64'h4000_0000;
    ret.AxiExtRegionEnd[1] = 64'h4001_0000;

    ret.Dma        = 1;
    ret.Uart       = 0;
    ret.I2c        = 0;
    ret.SpiHost    = 0;
    ret.Gpio       = 0;
    ret.SerialLink = 0;
    ret.Vga        = 0;
    ret.Usb        = 0;
    ret.AxiRt      = 0;
    ret.Clic       = 0;
    ret.IrqRouter  = 0;
    ret.BusErr     = 0;

    return ret;
  endfunction

  localparam cheshire_cfg_t DutCfg = gen_test_cfg();

  `CHESHIRE_TYPEDEF_ALL(, DutCfg)

  logic clk;
  logic rst_n;

  axi_slv_req_t [0:0] ext_req;
  axi_slv_rsp_t [0:0] ext_rsp;
  axi_slv_req_t [0:0] mem_req;
  axi_slv_rsp_t [0:0] mem_rsp;
  axi_slv_req_t       delayed_req;
  axi_slv_rsp_t       delayed_rsp;

  logic stall_mode;
  logic read_error_mode;
  logic write_error_mode;
  logic expect_continue;
  logic expect_abort;
  logic allow_full_abort;
  int unsigned firmware_mode;
  int unsigned error_burst;

  logic error_injected;
  logic [47:0] error_addr;
  longint unsigned first_ar_count;
  longint unsigned first_aw_count;

  logic [0:0]                 mon_w_valid;
  logic [0:0][47:0]           mon_w_addr;
  logic [0:0][63:0]           mon_w_data;
  logic [0:0][$bits(axi_slv_id_t)-1:0] mon_w_id;
  logic [0:0][DutCfg.AxiUserWidth-1:0] mon_w_user;
  axi_pkg::len_t [0:0]        mon_w_beat_count;
  logic [0:0]                 mon_w_last;

  longint unsigned dma_busy_cycles;
  longint unsigned dma_issue_count;
  longint unsigned dma_retire_count;
  longint unsigned backend_rsp_count;
  longint unsigned backend_error_rsp_count;
  longint unsigned dma_ar_count;
  longint unsigned dma_aw_count;
  longint unsigned dma_r_beat_count;
  longint unsigned dma_w_beat_count;
  longint unsigned dma_b_count;
  longint unsigned dma_r_error_count;
  longint unsigned dma_b_error_count;
  longint unsigned axi_aw_wait_cycles;
  longint unsigned axi_w_wait_cycles;
  longint unsigned axi_b_wait_cycles;
  longint unsigned axi_ar_wait_cycles;
  longint unsigned axi_r_wait_cycles;

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
    .rtc_i              ( 1'b0 ),
    .axi_llc_mst_req_o  ( ),
    .axi_llc_mst_rsp_i  ( '0 ),
    .axi_ext_mst_req_i  ( '0 ),
    .axi_ext_mst_rsp_o  ( ),
    .axi_ext_slv_req_o  ( ext_req ),
    .axi_ext_slv_rsp_i  ( ext_rsp ),
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
    .uart_tx_o          ( ),
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

  axi_delayer #(
    .aw_chan_t         ( axi_slv_aw_chan_t ),
    .w_chan_t          ( axi_slv_w_chan_t  ),
    .b_chan_t          ( axi_slv_b_chan_t  ),
    .ar_chan_t         ( axi_slv_ar_chan_t ),
    .r_chan_t          ( axi_slv_r_chan_t  ),
    .axi_req_t         ( axi_slv_req_t     ),
    .axi_resp_t        ( axi_slv_rsp_t     ),
    .StallRandomInput  ( 1'b0              ),
    .StallRandomOutput ( 1'b0              ),
    .FixedDelayInput   ( 3                 ),
    .FixedDelayOutput  ( 5                 )
  ) i_ext_delayer (
    .clk_i              ( clk ),
    .rst_ni             ( rst_n ),
    .slv_req_i          ( ext_req[0] ),
    .slv_resp_o         ( delayed_rsp ),
    .mst_req_o          ( delayed_req ),
    .mst_resp_i         ( mem_rsp[0] )
  );

  always_comb begin
    mem_req[0] = ext_req[0];
    ext_rsp[0] = mem_rsp[0];
    if (stall_mode) begin
      mem_req[0] = delayed_req;
      ext_rsp[0] = delayed_rsp;
    end
  end

  axi_sim_mem_reset #(
    .AddrWidth         ( DutCfg.AddrWidth ),
    .DataWidth         ( DutCfg.AxiDataWidth ),
    .IdWidth           ( $bits(axi_slv_id_t) ),
    .UserWidth         ( DutCfg.AxiUserWidth ),
    .NumPorts          ( 1 ),
    .axi_req_t         ( axi_slv_req_t ),
    .axi_rsp_t         ( axi_slv_rsp_t ),
    .WarnUninitialized ( 0 ),
    .UninitializedData ( "zeros" ),
    .ClearErrOnAccess  ( 1 ),
    .ApplDelay         ( ClockPeriod * 0.1 ),
    .AcqDelay          ( ClockPeriod * 0.9 )
  ) i_mem (
    .clk_i              ( clk ),
    .rst_ni             ( rst_n ),
    .axi_req_i          ( mem_req ),
    .axi_rsp_o          ( mem_rsp ),
    .mon_w_valid_o      ( mon_w_valid ),
    .mon_w_addr_o       ( mon_w_addr ),
    .mon_w_data_o       ( mon_w_data ),
    .mon_w_id_o         ( mon_w_id ),
    .mon_w_user_o       ( mon_w_user ),
    .mon_w_beat_count_o ( mon_w_beat_count ),
    .mon_w_last_o       ( mon_w_last ),
    .mon_r_valid_o      ( ),
    .mon_r_addr_o       ( ),
    .mon_r_data_o       ( ),
    .mon_r_id_o         ( ),
    .mon_r_user_o       ( ),
    .mon_r_beat_count_o ( ),
    .mon_r_last_o       ( )
  );

  always #(ClockPeriod / 2) clk = ~clk;

  always @(posedge clk) begin
    if (!rst_n) begin
      error_injected <= 1'b0;
      error_addr <= '0;
      first_ar_count <= 0;
      first_aw_count <= 0;
      dma_busy_cycles <= 0;
      dma_issue_count <= 0;
      dma_retire_count <= 0;
      backend_rsp_count <= 0;
      backend_error_rsp_count <= 0;
      dma_ar_count <= 0;
      dma_aw_count <= 0;
      dma_r_beat_count <= 0;
      dma_w_beat_count <= 0;
      dma_b_count <= 0;
      dma_r_error_count <= 0;
      dma_b_error_count <= 0;
      axi_aw_wait_cycles <= 0;
      axi_w_wait_cycles <= 0;
      axi_b_wait_cycles <= 0;
      axi_ar_wait_cycles <= 0;
      axi_r_wait_cycles <= 0;
    end else begin
      if (|i_dut.gen_dma.i_idma.busy)
        dma_busy_cycles <= dma_busy_cycles + 1;
      if (i_dut.gen_dma.i_idma.issue_id)
        dma_issue_count <= dma_issue_count + 1;
      if (i_dut.gen_dma.i_idma.retire_id)
        dma_retire_count <= dma_retire_count + 1;
      if (i_dut.gen_dma.i_idma.idma_rsp_valid &&
          i_dut.gen_dma.i_idma.idma_rsp_ready) begin
        backend_rsp_count <= backend_rsp_count + 1;
        if (read_error_mode || write_error_mode)
          $display("[TB] backend response %0d: error=%0d last=%0d done=%0d next=%0d",
                   backend_rsp_count + 1,
                   i_dut.gen_dma.i_idma.idma_rsp.error,
                   i_dut.gen_dma.i_idma.idma_rsp.last,
                   i_dut.gen_dma.i_idma.done_id,
                   i_dut.gen_dma.i_idma.next_id);
        if (i_dut.gen_dma.i_idma.idma_rsp.error)
          backend_error_rsp_count <= backend_error_rsp_count + 1;
      end

      if (i_dut.gen_dma.i_idma.axi_read_req.ar_valid &&
          i_dut.gen_dma.i_idma.axi_read_rsp.ar_ready) begin
        dma_ar_count <= dma_ar_count + 1;
        if (i_dut.gen_dma.i_idma.axi_read_req.ar.addr >= FirstSrc &&
            i_dut.gen_dma.i_idma.axi_read_req.ar.addr < FirstSrc + FirstLen) begin
          if (read_error_mode && !error_injected &&
              first_ar_count == error_burst) begin
            i_mem.rerr[i_dut.gen_dma.i_idma.axi_read_req.ar.addr] =
                axi_pkg::RESP_SLVERR;
            error_injected <= 1'b1;
            error_addr <= i_dut.gen_dma.i_idma.axi_read_req.ar.addr;
            $display("[TB] injected one-shot read SLVERR at burst=%0d addr=0x%012x",
                     first_ar_count,
                     i_dut.gen_dma.i_idma.axi_read_req.ar.addr);
          end
          first_ar_count <= first_ar_count + 1;
        end
      end

      if (i_dut.gen_dma.i_idma.axi_write_req.aw_valid &&
          i_dut.gen_dma.i_idma.axi_write_rsp.aw_ready) begin
        dma_aw_count <= dma_aw_count + 1;
        if (i_dut.gen_dma.i_idma.axi_write_req.aw.addr >= FirstDst &&
            i_dut.gen_dma.i_idma.axi_write_req.aw.addr < FirstDst + FirstLen) begin
          if (write_error_mode && !error_injected &&
              first_aw_count == error_burst) begin
            i_mem.werr[i_dut.gen_dma.i_idma.axi_write_req.aw.addr] =
                axi_pkg::RESP_SLVERR;
            error_injected <= 1'b1;
            error_addr <= i_dut.gen_dma.i_idma.axi_write_req.aw.addr;
            $display("[TB] injected one-shot write SLVERR at burst=%0d addr=0x%012x",
                     first_aw_count,
                     i_dut.gen_dma.i_idma.axi_write_req.aw.addr);
          end
          first_aw_count <= first_aw_count + 1;
        end
      end

      if (i_dut.gen_dma.i_idma.axi_read_rsp.r_valid &&
          i_dut.gen_dma.i_idma.axi_read_req.r_ready) begin
        dma_r_beat_count <= dma_r_beat_count + 1;
        if (i_dut.gen_dma.i_idma.axi_read_rsp.r.resp != axi_pkg::RESP_OKAY)
          dma_r_error_count <= dma_r_error_count + 1;
      end
      if (i_dut.gen_dma.i_idma.axi_write_req.w_valid &&
          i_dut.gen_dma.i_idma.axi_write_rsp.w_ready)
        dma_w_beat_count <= dma_w_beat_count + 1;
      if (i_dut.gen_dma.i_idma.axi_write_rsp.b_valid &&
          i_dut.gen_dma.i_idma.axi_write_req.b_ready) begin
        dma_b_count <= dma_b_count + 1;
        if (i_dut.gen_dma.i_idma.axi_write_rsp.b.resp != axi_pkg::RESP_OKAY)
          dma_b_error_count <= dma_b_error_count + 1;
      end

      if (ext_req[0].aw_valid && !ext_rsp[0].aw_ready)
        axi_aw_wait_cycles <= axi_aw_wait_cycles + 1;
      if (ext_req[0].w_valid && !ext_rsp[0].w_ready)
        axi_w_wait_cycles <= axi_w_wait_cycles + 1;
      if (mem_rsp[0].b_valid && !mem_req[0].b_ready)
        axi_b_wait_cycles <= axi_b_wait_cycles + 1;
      if (ext_req[0].ar_valid && !ext_rsp[0].ar_ready)
        axi_ar_wait_cycles <= axi_ar_wait_cycles + 1;
      if (mem_rsp[0].r_valid && !mem_req[0].r_ready)
        axi_r_wait_cycles <= axi_r_wait_cycles + 1;
    end
  end

  initial begin
    string firmware;
    clk = 1'b0;
    rst_n = 1'b0;
    stall_mode = $test$plusargs("AXI_STALLS");
    read_error_mode = $test$plusargs("READ_ERROR");
    write_error_mode = $test$plusargs("WRITE_ERROR");
    expect_continue = $test$plusargs("EXPECT_CONTINUE");
    expect_abort = $test$plusargs("EXPECT_ABORT");
    allow_full_abort = $test$plusargs("ALLOW_FULL_ABORT");
    error_burst = 0;
    void'($value$plusargs("ERROR_BURST=%d", error_burst));

    if (read_error_mode && write_error_mode)
      $fatal(1, "READ_ERROR and WRITE_ERROR are mutually exclusive");
    if (expect_continue && expect_abort)
      $fatal(1, "EXPECT_CONTINUE and EXPECT_ABORT are mutually exclusive");
    if (allow_full_abort && !expect_abort)
      $fatal(1, "ALLOW_FULL_ABORT requires EXPECT_ABORT");
    if ((read_error_mode || write_error_mode) !=
        (expect_continue || expect_abort))
      $fatal(1, "error injection requires exactly one expected behavior");

    if (expect_abort)
      firmware_mode = allow_full_abort ? ModeExpectAbortAllowFull : ModeExpectAbort;
    else if (expect_continue)
      firmware_mode = ModeExpectContinue;
    else
      firmware_mode = ModeClean;

    if (!$value$plusargs("MEMH=%s", firmware))
      $fatal(1, "missing +MEMH=<firmware.memh>");
    $display("[TB] loading CVA6 firmware: %s", firmware);
    $display("[TB] mode: firmware=%0d axi_stalls=%0d read_error=%0d write_error=%0d error_burst=%0d",
             firmware_mode, stall_mode, read_error_mode, write_error_mode,
             error_burst);
    $readmemh(firmware, i_mem.mem);
    i_mem.mem[ModeAddr + 0] = firmware_mode[7:0];
    i_mem.mem[ModeAddr + 1] = 8'h00;
    i_mem.mem[ModeAddr + 2] = 8'h00;
    i_mem.mem[ModeAddr + 3] = 8'h00;
    repeat (20) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  end

  always @(posedge clk) begin
    if (rst_n && mon_w_valid[0] && mon_w_addr[0] == CompletionAddr) begin
      $display("[TB] completion: value=0x%016x prefix=%0d rc=%0d",
               mon_w_data[0], mon_w_data[0][31:16], mon_w_data[0][15:0]);
      $display("[TB] DMA activity: jobs=%0d/%0d busy_cycles=%0d ar=%0d aw=%0d r=%0d w=%0d b=%0d backend_rsp=%0d backend_err=%0d",
               dma_issue_count, dma_retire_count, dma_busy_cycles,
               dma_ar_count, dma_aw_count, dma_r_beat_count,
               dma_w_beat_count, dma_b_count, backend_rsp_count,
               backend_error_rsp_count);
      $display("[TB] AXI errors: read=%0d write=%0d injected=%0d addr=0x%012x",
               dma_r_error_count, dma_b_error_count,
               error_injected, error_addr);
      $display("[TB] AXI wait cycles: aw=%0d w=%0d b=%0d ar=%0d r=%0d",
               axi_aw_wait_cycles, axi_w_wait_cycles, axi_b_wait_cycles,
               axi_ar_wait_cycles, axi_r_wait_cycles);
      $display("[TB] IDs: done=%0d next=%0d",
               i_dut.gen_dma.i_idma.done_id,
               i_dut.gen_dma.i_idma.next_id);

      if ((mon_w_data[0] & 64'hffff_ffff_0000_0000) != CompletionMagic)
        $fatal(1, "bad completion magic: 0x%016x", mon_w_data[0]);
      if (mon_w_data[0][15:0] != 0)
        $fatal(1, "CVA6 DMA error firmware failed: code %0d",
               mon_w_data[0][15:0]);
      if (firmware_mode == ModeExpectAbort &&
          mon_w_data[0][31:16] >= FirstLen)
        $fatal(1, "abort did not shorten the first transfer: prefix=%0d",
               mon_w_data[0][31:16]);
      if (firmware_mode != ModeExpectAbort &&
          firmware_mode != ModeExpectAbortAllowFull &&
          mon_w_data[0][31:16] != FirstLen)
        $fatal(1, "first transfer did not complete: prefix=%0d",
               mon_w_data[0][31:16]);
      if (dma_issue_count != ExpectedJobs || dma_retire_count != ExpectedJobs)
        $fatal(1, "unexpected DMA job accounting: issue=%0d retire=%0d",
               dma_issue_count, dma_retire_count);
      if (i_dut.gen_dma.i_idma.done_id != ExpectedDoneId ||
          i_dut.gen_dma.i_idma.next_id != ExpectedNextId)
        $fatal(1, "unexpected transfer IDs: done=%0d next=%0d",
               i_dut.gen_dma.i_idma.done_id,
               i_dut.gen_dma.i_idma.next_id);
      if (dma_busy_cycles == 0 || dma_r_beat_count == 0 ||
          dma_w_beat_count == 0)
        $fatal(1, "DMA datapath was not observed active");
      if ((read_error_mode || write_error_mode) && !error_injected)
        $fatal(1, "requested AXI error was not injected");
      if (read_error_mode &&
          (dma_r_error_count == 0 || dma_b_error_count != 0))
        $fatal(1, "read-error response accounting mismatch");
      if (write_error_mode &&
          (dma_b_error_count == 0 || dma_r_error_count != 0))
        $fatal(1, "write-error response accounting mismatch");
      if (!read_error_mode && !write_error_mode &&
          (dma_r_error_count != 0 || dma_b_error_count != 0))
        $fatal(1, "unexpected AXI error response in clean run");
      if ((firmware_mode == ModeExpectAbort ||
           firmware_mode == ModeExpectAbortAllowFull) &&
          backend_error_rsp_count == 0)
        $fatal(1, "error-capable backend did not report the AXI error");
      if (firmware_mode != ModeExpectAbort &&
          firmware_mode != ModeExpectAbortAllowFull &&
          backend_error_rsp_count != 0)
        $fatal(1, "backend reported an unexpected error response");
      if (stall_mode &&
          (axi_aw_wait_cycles == 0 || axi_w_wait_cycles == 0 ||
           axi_b_wait_cycles == 0 || axi_ar_wait_cycles == 0 ||
           axi_r_wait_cycles == 0))
        $fatal(1, "AXI_STALLS did not block all five channels");

      $display("[TB] CVA6+iDMA error-policy PASS");
      $finish;
    end
  end

  initial begin
    repeat (3_000_000) @(posedge clk);
    $display("[TB] timeout diagnostics: jobs=%0d/%0d backend_rsp=%0d backend_err=%0d done=%0d next=%0d",
             dma_issue_count, dma_retire_count, backend_rsp_count,
             backend_error_rsp_count, i_dut.gen_dma.i_idma.done_id,
             i_dut.gen_dma.i_idma.next_id);
    $display("[TB] timeout AXI: ar=%0d aw=%0d r=%0d w=%0d b=%0d rerr=%0d berr=%0d",
             dma_ar_count, dma_aw_count, dma_r_beat_count,
             dma_w_beat_count, dma_b_count,
             dma_r_error_count, dma_b_error_count);
    $fatal(1, "timeout waiting for CVA6 DMA error-policy completion");
  end

endmodule
