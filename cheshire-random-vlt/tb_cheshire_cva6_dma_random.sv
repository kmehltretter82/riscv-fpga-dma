`timescale 1ns/1ps

module tb_cheshire_cva6_dma_random;

  `include "cheshire/typedef.svh"

  import cheshire_pkg::*;

  localparam time ClockPeriod = 10ns;
  localparam logic [47:0] SeedAddr       = 48'h0000_4000_fec0;
  localparam logic [47:0] CountAddr      = 48'h0000_4000_fec4;
  localparam logic [47:0] FlagsAddr      = 48'h0000_4000_fec8;
  localparam logic [47:0] SkipAddr       = 48'h0000_4000_fecc;
  localparam logic [47:0] MaskAddr       = 48'h0000_4000_fed0;
  localparam logic [47:0] DiagAddr       = 48'h0000_4000_fd00;
  localparam logic [47:0] CompletionAddr = 48'h0000_4000_fff8;
  localparam logic [63:0] CompletionMagic = 64'h524e_444d_0000_0000;
  localparam logic [31:0] DiagnosticMagic = 32'h524e_4447;
  localparam int unsigned TimingDirect = 0;
  localparam int unsigned TimingFixed  = 1;
  localparam int unsigned TimingRandom = 2;

  function automatic cheshire_cfg_t gen_test_cfg();
    cheshire_cfg_t ret = DefaultCfg;

    // Boot CVA6 directly from the externally backed cached executable region.
    ret.Bootrom      = 0;
    ret.PlatformRom  = 32'h2000_0000;

    // Use one external AXI slave as memory.  The lower region is cached and
    // executable; the upper region is non-idempotent and therefore uncached.
    ret.LlcNotBypass = 0;
    ret.LlcOutConnect = 0;
    ret.AxiExtNumSlv = 1;
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

    // Retain one CVA6 core, iDMA, registers, CLINT and PLIC.  Peripheral
    // blocks irrelevant to this CPU-to-DMA test are disabled.
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
  axi_slv_req_t       fixed_slv_req;
  axi_slv_rsp_t       fixed_slv_rsp;
  axi_slv_req_t       fixed_mst_req;
  axi_slv_req_t       random_slv_req;
  axi_slv_rsp_t       random_slv_rsp;
  axi_slv_req_t       random_mst_req;

  int unsigned timing_mode;
  logic reset_mode;
  logic duration_profile;
  logic reset_injected;
  logic read_error_mode;
  logic write_error_mode;
  logic trace_reduce;
  logic error_injected;
  logic [47:0] error_addr;
  int unsigned geometry_seed;
  int unsigned timing_seed;
  int unsigned case_count;
  int unsigned skip_cases;
  int unsigned execute_mask;
  int unsigned expected_jobs;
  int unsigned expected_hash;
  int unsigned error_job;
  int unsigned error_burst;
  longint unsigned job_ar_count;
  longint unsigned job_aw_count;

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
  logic [31:0] observed_diag_magic;
  logic [31:0] observed_seed;
  logic [31:0] observed_requested;
  logic [31:0] observed_completed;
  logic [31:0] observed_index;
  logic [31:0] observed_kind;
  logic [31:0] observed_reason;
  logic [31:0] observed_conf;
  logic [31:0] observed_src;
  logic [31:0] observed_dst;
  logic [31:0] observed_len;
  logic [31:0] observed_src_stride;
  logic [31:0] observed_dst_stride;
  logic [31:0] observed_rows;
  logic [31:0] observed_hash;
  logic [31:0] observed_rng_state;

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

  // Fixed-delay and bounded pseudo-random paths share one executable.  Their
  // slave inputs are gated below, and timing_mode stays constant for a run.
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
  ) i_fixed_delayer (
    .clk_i              ( clk           ),
    .rst_ni             ( rst_n         ),
    .slv_req_i          ( fixed_slv_req ),
    .slv_resp_o         ( fixed_slv_rsp ),
    .mst_req_o          ( fixed_mst_req ),
    .mst_resp_i         ( mem_rsp[0]    )
  );

  axi_bounded_delayer #(
    .aw_chan_t         ( axi_slv_aw_chan_t ),
    .w_chan_t          ( axi_slv_w_chan_t  ),
    .b_chan_t          ( axi_slv_b_chan_t  ),
    .ar_chan_t         ( axi_slv_ar_chan_t ),
    .r_chan_t          ( axi_slv_r_chan_t  ),
    .axi_req_t         ( axi_slv_req_t     ),
    .axi_resp_t        ( axi_slv_rsp_t     ),
    .MaxDelay          ( 7                 )
  ) i_random_delayer (
    .clk_i              ( clk            ),
    .rst_ni             ( rst_n          ),
    .seed_i             ( timing_seed    ),
    .slv_req_i          ( random_slv_req ),
    .slv_resp_o         ( random_slv_rsp ),
    .mst_req_o          ( random_mst_req ),
    .mst_resp_i         ( mem_rsp[0]     )
  );

  always_comb begin
    fixed_slv_req = '0;
    random_slv_req = '0;
    mem_req[0] = ext_req[0];
    ext_rsp[0] = mem_rsp[0];
    if (timing_mode == TimingFixed) begin
      fixed_slv_req = ext_req[0];
      mem_req[0] = fixed_mst_req;
      ext_rsp[0] = fixed_slv_rsp;
    end else if (timing_mode == TimingRandom) begin
      random_slv_req = ext_req[0];
      mem_req[0] = random_mst_req;
      ext_rsp[0] = random_slv_rsp;
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

  task automatic mem_write_u32(input logic [47:0] addr,
                               input logic [31:0] value);
    for (int unsigned byte_idx = 0; byte_idx < 4; ++byte_idx)
      i_mem.mem[addr + byte_idx] = value[byte_idx * 8 +: 8];
  endtask

  function automatic logic [31:0] mem_read_u32(input logic [47:0] addr);
    logic [31:0] value;
    for (int unsigned byte_idx = 0; byte_idx < 4; ++byte_idx)
      value[byte_idx * 8 +: 8] = i_mem.mem[addr + byte_idx];
    return value;
  endfunction

  always #(ClockPeriod / 2) clk = ~clk;

  always @(posedge clk) begin
    if (!rst_n) begin
      dma_busy_cycles  <= 0;
      dma_issue_count  <= 0;
      dma_retire_count <= 0;
      dma_ar_count     <= 0;
      dma_aw_count     <= 0;
      dma_r_beat_count <= 0;
      dma_w_beat_count <= 0;
      dma_b_count      <= 0;
      dma_r_error_count <= 0;
      dma_b_error_count <= 0;
      job_ar_count <= 0;
      job_aw_count <= 0;
      axi_aw_wait_cycles <= 0;
      axi_w_wait_cycles  <= 0;
      axi_b_wait_cycles  <= 0;
      axi_ar_wait_cycles <= 0;
      axi_r_wait_cycles  <= 0;
    end else begin
      if (|i_dut.gen_dma.i_idma.busy)
        dma_busy_cycles <= dma_busy_cycles + 1;
      if (i_dut.gen_dma.i_idma.issue_id)
        dma_issue_count <= dma_issue_count + 1;
      if (i_dut.gen_dma.i_idma.retire_id)
        dma_retire_count <= dma_retire_count + 1;
      if (i_dut.gen_dma.i_idma.retire_id) begin
        job_ar_count <= 0;
        job_aw_count <= 0;
      end
      if (i_dut.gen_dma.i_idma.axi_read_req.ar_valid &&
          i_dut.gen_dma.i_idma.axi_read_rsp.ar_ready) begin
        dma_ar_count <= dma_ar_count + 1;
        job_ar_count <= job_ar_count + 1;
      end
      if (i_dut.gen_dma.i_idma.axi_write_req.aw_valid &&
          i_dut.gen_dma.i_idma.axi_write_rsp.aw_ready) begin
        dma_aw_count <= dma_aw_count + 1;
        job_aw_count <= job_aw_count + 1;
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

  always @(posedge clk) begin
    if (rst_n && trace_reduce) begin
      if (i_dut.gen_dma.i_idma.issue_id)
        $display("[REDUCE] issue job=%0d case=%0d", dma_issue_count,
                 mem_read_u32(DiagAddr + 16));
      if (i_dut.gen_dma.i_idma.i_idma_backend.w_valid &&
          i_dut.gen_dma.i_idma.i_idma_backend.w_ready)
        $display("[REDUCE] meta aw=0x%012x len=%0d decouple_aw=%0b last=%0b super_last=%0b",
                 i_dut.gen_dma.i_idma.i_idma_backend.w_req.aw_req.axi.aw_chan.addr,
                 i_dut.gen_dma.i_idma.i_idma_backend.w_req.aw_req.axi.aw_chan.len,
                 i_dut.gen_dma.i_idma.i_idma_backend.w_req.decouple_aw,
                 i_dut.gen_dma.i_idma.i_idma_backend.w_req.last,
                 i_dut.gen_dma.i_idma.i_idma_backend.w_req.super_last);
      if (i_dut.gen_dma.i_idma.axi_read_req.ar_valid &&
          i_dut.gen_dma.i_idma.axi_read_rsp.ar_ready)
        $display("[REDUCE] AR addr=0x%012x len=%0d",
                 i_dut.gen_dma.i_idma.axi_read_req.ar.addr,
                 i_dut.gen_dma.i_idma.axi_read_req.ar.len);
      if (i_dut.gen_dma.i_idma.axi_write_req.aw_valid &&
          i_dut.gen_dma.i_idma.axi_write_rsp.aw_ready)
        $display("[REDUCE] AW addr=0x%012x len=%0d",
                 i_dut.gen_dma.i_idma.axi_write_req.aw.addr,
                 i_dut.gen_dma.i_idma.axi_write_req.aw.len);
      if (i_dut.gen_dma.i_idma.axi_read_rsp.r_valid &&
          i_dut.gen_dma.i_idma.axi_read_req.r_ready)
        $display("[REDUCE] R last=%0b", i_dut.gen_dma.i_idma.axi_read_rsp.r.last);
      if (i_dut.gen_dma.i_idma.axi_write_req.w_valid &&
          i_dut.gen_dma.i_idma.axi_write_rsp.w_ready)
        $display("[REDUCE] W strb=0x%x last=%0b",
                 i_dut.gen_dma.i_idma.axi_write_req.w.strb,
                 i_dut.gen_dma.i_idma.axi_write_req.w.last);
      if (i_dut.gen_dma.i_idma.axi_write_rsp.b_valid &&
          i_dut.gen_dma.i_idma.axi_write_req.b_ready)
        $display("[REDUCE] B last_meta=%0b super_last=%0b",
                 i_dut.gen_dma.i_idma.i_idma_backend.w_last_burst,
                 i_dut.gen_dma.i_idma.i_idma_backend.w_super_last);
      if (i_dut.gen_dma.i_idma.retire_id)
        $display("[REDUCE] retire job=%0d case=%0d", dma_retire_count,
                 mem_read_u32(DiagAddr + 16));
    end
  end

  // Install an error before the following rising-edge transfer.  W can reach
  // the memory on the same edge as AW, especially when the channels are
  // decoupled, so changing werr from the rising-edge monitor is too late.
  always @(negedge clk) begin
    if (!rst_n) begin
      error_injected <= 1'b0;
      error_addr <= '0;
    end else if (read_error_mode && !error_injected &&
                 dma_retire_count == error_job &&
                 job_ar_count == error_burst &&
                 i_dut.gen_dma.i_idma.axi_read_req.ar_valid) begin
      if (error_burst == 0)
        i_mem.rerr[mem_read_u32(DiagAddr + 32)] = axi_pkg::RESP_SLVERR;
      else
        i_mem.rerr[i_dut.gen_dma.i_idma.axi_read_req.ar.addr] =
            axi_pkg::RESP_SLVERR;
      error_injected <= 1'b1;
      error_addr <= error_burst == 0 ? mem_read_u32(DiagAddr + 32) :
                    i_dut.gen_dma.i_idma.axi_read_req.ar.addr;
      $display("[TB] injected read SLVERR: job=%0d burst=%0d addr=0x%012x",
               dma_retire_count, job_ar_count,
               error_burst == 0 ? mem_read_u32(DiagAddr + 32) :
               i_dut.gen_dma.i_idma.axi_read_req.ar.addr);
    end else if (write_error_mode && !error_injected &&
                 dma_retire_count == error_job &&
                 job_aw_count == error_burst &&
                 i_dut.gen_dma.i_idma.axi_write_req.aw_valid) begin
      if (error_burst == 0)
        i_mem.werr[mem_read_u32(DiagAddr + 36)] = axi_pkg::RESP_SLVERR;
      else
        i_mem.werr[i_dut.gen_dma.i_idma.axi_write_req.aw.addr] =
            axi_pkg::RESP_SLVERR;
      error_injected <= 1'b1;
      error_addr <= error_burst == 0 ? mem_read_u32(DiagAddr + 36) :
                    i_dut.gen_dma.i_idma.axi_write_req.aw.addr;
      $display("[TB] injected write SLVERR: job=%0d burst=%0d addr=0x%012x",
               dma_retire_count, job_aw_count,
               error_burst == 0 ? mem_read_u32(DiagAddr + 36) :
               i_dut.gen_dma.i_idma.axi_write_req.aw.addr);
    end
  end

  initial begin
    string firmware;
    clk = 1'b0;
    rst_n = 1'b0;
    timing_mode = TimingDirect;
    if ($test$plusargs("AXI_FIXED")) timing_mode = TimingFixed;
    if ($test$plusargs("AXI_RANDOM")) begin
      if (timing_mode != TimingDirect)
        $fatal(1, "AXI_FIXED and AXI_RANDOM are mutually exclusive");
      timing_mode = TimingRandom;
    end
    reset_mode = $test$plusargs("DMA_RESET");
    duration_profile = $test$plusargs("PROFILE_DURATION");
    read_error_mode = $test$plusargs("READ_ERROR");
    write_error_mode = $test$plusargs("WRITE_ERROR");
    trace_reduce = $test$plusargs("TRACE_REDUCE");
    reset_injected = 1'b0;
    error_job = 0;
    error_burst = 0;
    skip_cases = 0;
    execute_mask = 0;
    if (!$value$plusargs("SEED=%h", geometry_seed))
      $fatal(1, "missing +SEED=<hex>");
    if (!$value$plusargs("CASES=%d", case_count))
      $fatal(1, "missing +CASES=<decimal>");
    if (!$value$plusargs("TIMING_SEED=%h", timing_seed))
      $fatal(1, "missing +TIMING_SEED=<hex>");
    if (!$value$plusargs("EXPECT_HASH=%h", expected_hash))
      $fatal(1, "missing +EXPECT_HASH=<hex>");
    void'($value$plusargs("ERROR_JOB=%d", error_job));
    void'($value$plusargs("ERROR_BURST=%d", error_burst));
    void'($value$plusargs("SKIP_CASES=%d", skip_cases));
    void'($value$plusargs("EXEC_MASK=%h", execute_mask));
    if (case_count == 0 || case_count > 1024)
      $fatal(1, "CASES must be in 1..1024");
    if (skip_cases > case_count)
      $fatal(1, "SKIP_CASES must not exceed CASES");
    if ((skip_cases != 0 || execute_mask != 0) &&
        (reset_mode || read_error_mode || write_error_mode))
      $fatal(1, "SKIP_CASES/EXEC_MASK are only supported for clean diagnostics");
    expected_jobs = 0;
    for (int unsigned index = skip_cases; index < case_count; index++) begin
      if (execute_mask == 0 ||
          ((index - skip_cases) < 32 && execute_mask[index - skip_cases]))
        expected_jobs++;
    end
    if (read_error_mode && write_error_mode)
      $fatal(1, "READ_ERROR and WRITE_ERROR are mutually exclusive");
    if ((read_error_mode || write_error_mode) && error_job >= case_count)
      $fatal(1, "ERROR_JOB must be below CASES");
    if (!$value$plusargs("MEMH=%s", firmware))
      $fatal(1, "missing +MEMH=<firmware.memh>");
    $display("[TB] loading CVA6 firmware: %s", firmware);
    $display("[TB] mode: seed=0x%08x cases=%0d skip=%0d mask=0x%08x jobs=%0d profile=%0d timing=%0d timing_seed=0x%08x reset=%0d read_error=%0d write_error=%0d error_job=%0d error_burst=%0d expected_hash=0x%08x",
             geometry_seed, case_count, skip_cases, execute_mask, expected_jobs,
             duration_profile, timing_mode, timing_seed,
             reset_mode, read_error_mode, write_error_mode,
             error_job, error_burst, expected_hash);
    $readmemh(firmware, i_mem.mem);
    mem_write_u32(SeedAddr, geometry_seed);
    mem_write_u32(CountAddr, case_count);
    mem_write_u32(FlagsAddr, duration_profile);
    mem_write_u32(SkipAddr, skip_cases);
    mem_write_u32(MaskAddr, execute_mask);
    repeat (20) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    if (reset_mode) begin
      wait (|i_dut.gen_dma.i_idma.busy);
      @(negedge clk);
      reset_injected = 1'b1;
      rst_n = 1'b0;
      $display("[TB] injected SoC reset while iDMA busy");
      repeat (12) @(posedge clk);
      @(negedge clk);
      rst_n = 1'b1;
    end
  end

  always @(posedge clk) begin
    if (rst_n && mon_w_valid[0] && mon_w_addr[0] == CompletionAddr) begin
      observed_diag_magic = mem_read_u32(DiagAddr + 0);
      observed_seed = mem_read_u32(DiagAddr + 4);
      observed_requested = mem_read_u32(DiagAddr + 8);
      observed_completed = mem_read_u32(DiagAddr + 12);
      observed_index = mem_read_u32(DiagAddr + 16);
      observed_kind = mem_read_u32(DiagAddr + 20);
      observed_reason = mem_read_u32(DiagAddr + 24);
      observed_conf = mem_read_u32(DiagAddr + 28);
      observed_src = mem_read_u32(DiagAddr + 32);
      observed_dst = mem_read_u32(DiagAddr + 36);
      observed_len = mem_read_u32(DiagAddr + 40);
      observed_src_stride = mem_read_u32(DiagAddr + 44);
      observed_dst_stride = mem_read_u32(DiagAddr + 48);
      observed_rows = mem_read_u32(DiagAddr + 52);
      observed_hash = mem_read_u32(DiagAddr + 56);
      observed_rng_state = mem_read_u32(DiagAddr + 60);
      $display("[TB] completion: value=0x%016x completed=%0d rc=%0d",
               mon_w_data[0], mon_w_data[0][31:16], mon_w_data[0][15:0]);
      $display("[TB] diagnostic: magic=0x%08x seed=0x%08x requested=%0d completed=%0d index=%0d kind=%0d reason=%0d conf=0x%x src=0x%08x dst=0x%08x len=%0d src_stride=%0d dst_stride=%0d rows=%0d hash=0x%08x rng=0x%08x",
               observed_diag_magic, observed_seed, observed_requested,
               observed_completed, observed_index, observed_kind,
               observed_reason, observed_conf, observed_src, observed_dst,
               observed_len, observed_src_stride, observed_dst_stride,
               observed_rows, observed_hash, observed_rng_state);
      $display("[TB] DMA activity: jobs=%0d/%0d busy_cycles=%0d ar=%0d aw=%0d r=%0d w=%0d b=%0d",
               dma_issue_count, dma_retire_count, dma_busy_cycles,
               dma_ar_count, dma_aw_count, dma_r_beat_count,
               dma_w_beat_count, dma_b_count);
      $display("[TB] AXI errors: read=%0d write=%0d injected=%0d addr=0x%012x",
               dma_r_error_count, dma_b_error_count,
               error_injected, error_addr);
      $display("[TB] AXI wait cycles: aw=%0d w=%0d b=%0d ar=%0d r=%0d",
               axi_aw_wait_cycles, axi_w_wait_cycles, axi_b_wait_cycles,
               axi_ar_wait_cycles, axi_r_wait_cycles);
      if ((mon_w_data[0] & 64'hffff_ffff_0000_0000) != CompletionMagic)
        $fatal(1, "bad completion magic: 0x%016x", mon_w_data[0]);
      if (mon_w_data[0][15:0] != 0)
        $fatal(1, "CVA6 random DMA firmware failed: code %0d case=%0d reason=%0d",
               mon_w_data[0][15:0], observed_index, observed_reason);
      if (mon_w_data[0][31:16] != case_count)
        $fatal(1, "completion count mismatch: value=%0d expected=%0d",
               mon_w_data[0][31:16], case_count);
      if (observed_diag_magic != DiagnosticMagic ||
          observed_seed != geometry_seed ||
          observed_requested != case_count ||
          observed_completed != case_count || observed_index != case_count ||
          observed_kind != 0 || observed_reason != 0)
        $fatal(1, "firmware diagnostic summary mismatch");
      if (observed_hash != expected_hash)
        $fatal(1, "descriptor hash mismatch: observed=0x%08x expected=0x%08x",
               observed_hash, expected_hash);
      if (dma_issue_count != expected_jobs || dma_retire_count != expected_jobs)
        $fatal(1, "unexpected DMA job accounting: issue=%0d retire=%0d",
               dma_issue_count, dma_retire_count);
      if (dma_busy_cycles == 0 || dma_r_beat_count == 0 || dma_w_beat_count == 0)
        $fatal(1, "DMA datapath was not observed active");
      if (reset_mode && !reset_injected)
        $fatal(1, "DMA_RESET requested but no reset was injected");
      if (timing_mode != TimingDirect &&
          (axi_aw_wait_cycles == 0 || axi_w_wait_cycles == 0 ||
           axi_b_wait_cycles == 0 || axi_ar_wait_cycles == 0 ||
           axi_r_wait_cycles == 0))
        $fatal(1, "selected AXI delay did not block all five channels");
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
        $fatal(1, "unexpected AXI error response");
      $display("[TB] CVA6+iDMA randomized campaign PASS");
      $finish;
    end
  end

  initial begin
    longint unsigned timeout_cycles = 20_000_000;
    void'($value$plusargs("TIMEOUT_CYCLES=%d", timeout_cycles));
    repeat (timeout_cycles) @(posedge clk);
    $display("[TB] timeout diagnostics: jobs=%0d/%0d busy=%0d ar=%0d aw=%0d r=%0d w=%0d b=%0d",
             dma_issue_count, dma_retire_count, dma_busy_cycles,
             dma_ar_count, dma_aw_count, dma_r_beat_count,
             dma_w_beat_count, dma_b_count);
    $display("[TB] timeout firmware: magic=0x%08x completed=%0d index=%0d kind=%0d reason=%0d conf=0x%x src=0x%08x dst=0x%08x len=%0d src_stride=%0d dst_stride=%0d rows=%0d hash=0x%08x rng=0x%08x",
             mem_read_u32(DiagAddr + 0), mem_read_u32(DiagAddr + 12),
             mem_read_u32(DiagAddr + 16), mem_read_u32(DiagAddr + 20),
             mem_read_u32(DiagAddr + 24), mem_read_u32(DiagAddr + 28),
             mem_read_u32(DiagAddr + 32), mem_read_u32(DiagAddr + 36),
             mem_read_u32(DiagAddr + 40), mem_read_u32(DiagAddr + 44),
             mem_read_u32(DiagAddr + 48), mem_read_u32(DiagAddr + 52),
             mem_read_u32(DiagAddr + 56), mem_read_u32(DiagAddr + 60));
    $display("[TB] timeout backend: busy=%b rsp=%0b/%0b last=%0b super_last=%0b w_last_ready=%0b",
             i_dut.gen_dma.i_idma.busy,
             i_dut.gen_dma.i_idma.i_idma_backend.rsp_valid,
             i_dut.gen_dma.i_idma.i_idma_backend.rsp_ready,
             i_dut.gen_dma.i_idma.i_idma_backend.w_last_burst,
             i_dut.gen_dma.i_idma.i_idma_backend.w_super_last,
             i_dut.gen_dma.i_idma.i_idma_backend.w_last_ready);
    $display("[TB] timeout write: req_valid=%0b req_ready=%0b offset=%0d tailer=%0d shift=%0d beats=%0d single=%0b buffer=0x%x shifted=0x%x mask=0x%x ready=%0b first=%0b last=%0b cnt_valid=%0b cnt=%0d",
             i_dut.gen_dma.i_idma.i_idma_backend.w_dp_req_out_valid,
             i_dut.gen_dma.i_idma.i_idma_backend.w_dp_req_out_ready,
             i_dut.gen_dma.i_idma.i_idma_backend.w_dp_req_out.offset,
             i_dut.gen_dma.i_idma.i_idma_backend.w_dp_req_out.tailer,
             i_dut.gen_dma.i_idma.i_idma_backend.w_dp_req_out.shift,
             i_dut.gen_dma.i_idma.i_idma_backend.w_dp_req_out.num_beats,
             i_dut.gen_dma.i_idma.i_idma_backend.w_dp_req_out.is_single,
             i_dut.gen_dma.i_idma.i_idma_backend.i_idma_transport_layer.buffer_out_valid,
             i_dut.gen_dma.i_idma.i_idma_backend.i_idma_transport_layer.buffer_out_valid_shifted,
             i_dut.gen_dma.i_idma.i_idma_backend.i_idma_transport_layer.i_idma_axi_write.mask_out,
             i_dut.gen_dma.i_idma.i_idma_backend.i_idma_transport_layer.i_idma_axi_write.ready_to_write,
             i_dut.gen_dma.i_idma.i_idma_backend.i_idma_transport_layer.i_idma_axi_write.first_w,
             i_dut.gen_dma.i_idma.i_idma_backend.i_idma_transport_layer.i_idma_axi_write.last_w,
             i_dut.gen_dma.i_idma.i_idma_backend.i_idma_transport_layer.i_idma_axi_write.w_cnt_valid_q,
             i_dut.gen_dma.i_idma.i_idma_backend.i_idma_transport_layer.i_idma_axi_write.w_num_beats_q);
    $display("[TB] timeout coupler: credits=%0d aw_valid=%0b head_decoupled=%0b first=%0b ready_decoupled=%0b sent=%0b out=%0b/%0b",
             i_dut.gen_dma.i_idma.i_idma_backend.gen_r_aw_coupler.i_idma_channel_coupler.aw_to_send_q,
             i_dut.gen_dma.i_idma.i_idma_backend.gen_r_aw_coupler.i_idma_channel_coupler.aw_valid,
             i_dut.gen_dma.i_idma.i_idma_backend.gen_r_aw_coupler.i_idma_channel_coupler.aw_decoupled_head,
             i_dut.gen_dma.i_idma.i_idma_backend.gen_r_aw_coupler.i_idma_channel_coupler.first,
             i_dut.gen_dma.i_idma.i_idma_backend.gen_r_aw_coupler.i_idma_channel_coupler.aw_ready_decoupled,
             i_dut.gen_dma.i_idma.i_idma_backend.gen_r_aw_coupler.i_idma_channel_coupler.aw_sent,
             i_dut.gen_dma.i_idma.i_idma_backend.gen_r_aw_coupler.i_idma_channel_coupler.aw_valid_o,
             i_dut.gen_dma.i_idma.i_idma_backend.gen_r_aw_coupler.i_idma_channel_coupler.aw_ready_i);
    $fatal(1, "timeout after %0d cycles waiting for CVA6 randomized DMA completion",
           timeout_cycles);
  end

endmodule

