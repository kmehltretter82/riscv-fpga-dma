// SPDX-License-Identifier: Apache-2.0
// Open Verilator testbench for Cheshire's exact iDMA v0.6.4 integration wrapper.

`timescale 1ns/1ps
`include "axi/typedef.svh"

module tb_cheshire_idma_wrap #(
  parameter bit DutTwoD = 1'b1
);

  localparam int unsigned AddrWidth = 64;
  localparam int unsigned DataWidth = 64;
  localparam int unsigned IdWidth = 2;
  localparam int unsigned UserWidth = 1;
  localparam int unsigned StrbWidth = DataWidth / 8;
  localparam time ClockPeriod = 10ns;
  localparam int unsigned TimeoutCycles = 200000;

  localparam logic [63:0] RegConf      = 64'h0000;
  localparam logic [63:0] RegStatus    = 64'h0004;
  localparam logic [63:0] RegNextId    = 64'h0044;
  localparam logic [63:0] RegDoneId    = 64'h0084;
  localparam logic [63:0] RegDst       = 64'h00d0;
  localparam logic [63:0] RegSrc       = 64'h00d8;
  localparam logic [63:0] RegLength    = 64'h00e0;
  localparam logic [63:0] RegDstStride = 64'h00e8;
  localparam logic [63:0] RegSrcStride = 64'h00f0;
  localparam logic [63:0] RegReps      = 64'h00f8;
  localparam logic [31:0] ConfEnableNd = 32'h0000_0400;

  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [DataWidth-1:0] data_t;
  typedef logic [IdWidth-1:0] id_t;
  typedef logic [UserWidth-1:0] user_t;
  typedef logic [StrbWidth-1:0] strb_t;

  `AXI_TYPEDEF_ALL(cfg_axi, addr_t, id_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_ALL(mem_axi, addr_t, id_t, data_t, strb_t, user_t)

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  cfg_axi_req_t cfg_req;
  cfg_axi_resp_t cfg_rsp;
  mem_axi_req_t mem_req;
  mem_axi_resp_t mem_rsp;

  always #(ClockPeriod / 2) clk = ~clk;

  initial begin
    cfg_req = '0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
  end

  cheshire_idma_wrap #(
    .AxiAddrWidth     ( AddrWidth      ),
    .AxiDataWidth     ( DataWidth      ),
    .AxiIdWidth       ( IdWidth        ),
    .AxiUserWidth     ( UserWidth      ),
    .AxiSlvIdWidth    ( IdWidth        ),
    .NumAxInFlight    ( 4              ),
    .MemSysDepth      ( 4              ),
    .JobFifoDepth     ( 2              ),
    .RAWCouplingAvail ( 1'b1           ),
    .IsTwoD           ( DutTwoD        ),
    .axi_mst_req_t    ( mem_axi_req_t  ),
    .axi_mst_rsp_t    ( mem_axi_resp_t ),
    .axi_slv_req_t    ( cfg_axi_req_t  ),
    .axi_slv_rsp_t    ( cfg_axi_resp_t )
  ) i_dut (
    .clk_i         ( clk     ),
    .rst_ni        ( rst_n   ),
    .testmode_i    ( 1'b0    ),
    .axi_mst_req_o ( mem_req ),
    .axi_mst_rsp_i ( mem_rsp ),
    .axi_slv_req_i ( cfg_req ),
    .axi_slv_rsp_o ( cfg_rsp )
  );

  // Byte-addressed AXI memory.  The deliberate ready gaps exercise backpressure
  // while retaining at most one read and one write burst at a time.
  logic [7:0] memory [addr_t];
  longint unsigned memory_cycle;
  logic read_active, write_active, aw_wait_armed;
  addr_t read_addr, write_addr;
  axi_pkg::size_t read_size, write_size;
  axi_pkg::burst_t read_burst, write_burst;
  int unsigned read_beats_left, write_beats_left;
  id_t read_id, write_id;
  logic read_valid, write_resp_valid;
  mem_axi_r_chan_t read_chan;
  mem_axi_b_chan_t write_resp_chan;

  longint unsigned ar_count, aw_count, r_count, w_count, b_count;
  longint unsigned ar_stall_count, aw_stall_count, r_stall_count, w_stall_count;

  function automatic addr_t aligned_word(input addr_t address);
    return address & ~addr_t'(StrbWidth - 1);
  endfunction

  function automatic data_t load_word(input addr_t address);
    automatic data_t value = '0;
    automatic addr_t base = aligned_word(address);
    for (int unsigned lane = 0; lane < StrbWidth; lane++) begin
      if (memory.exists(base + lane)) value[lane*8 +: 8] = memory[base + lane];
    end
    return value;
  endfunction

  function automatic logic [7:0] load_byte(input addr_t address);
    if (memory.exists(address)) return memory[address];
    return 8'hxx;
  endfunction

  function automatic addr_t next_burst_addr(
    input addr_t address,
    input axi_pkg::size_t size,
    input axi_pkg::burst_t burst
  );
    if (burst == axi_pkg::BURST_INCR) return address + (addr_t'(1) << size);
    if (burst == axi_pkg::BURST_FIXED) return address;
    $fatal(1, "memory model does not support AXI burst type %0d", burst);
    return address;
  endfunction

  always_comb begin
    mem_rsp = '0;
    mem_rsp.ar_ready = !read_active && (memory_cycle[2:0] != 3'd2);
    mem_rsp.aw_ready = aw_wait_armed && !write_active && !write_resp_valid &&
                       (memory_cycle[2:0] != 3'd3);
    mem_rsp.w_ready = write_active && !write_resp_valid &&
                      (memory_cycle[1:0] != 2'd1);
    mem_rsp.r_valid = read_valid;
    mem_rsp.r = read_chan;
    mem_rsp.b_valid = write_resp_valid;
    mem_rsp.b = write_resp_chan;
  end

  always_ff @(posedge clk or negedge rst_n) begin : memory_model
    if (!rst_n) begin
      memory_cycle <= 0;
      read_active <= 1'b0;
      write_active <= 1'b0;
      aw_wait_armed <= 1'b0;
      read_valid <= 1'b0;
      write_resp_valid <= 1'b0;
      read_addr <= '0;
      write_addr <= '0;
      read_size <= '0;
      write_size <= '0;
      read_burst <= axi_pkg::BURST_INCR;
      write_burst <= axi_pkg::BURST_INCR;
      read_beats_left <= 0;
      write_beats_left <= 0;
      read_id <= '0;
      write_id <= '0;
      read_chan <= '0;
      write_resp_chan <= '0;
      ar_count <= 0;
      aw_count <= 0;
      r_count <= 0;
      w_count <= 0;
      b_count <= 0;
      ar_stall_count <= 0;
      aw_stall_count <= 0;
      r_stall_count <= 0;
      w_stall_count <= 0;
    end else begin
      memory_cycle <= memory_cycle + 1;

      if (mem_req.ar_valid && !mem_rsp.ar_ready) ar_stall_count <= ar_stall_count + 1;
      if (mem_req.aw_valid && !mem_rsp.aw_ready) aw_stall_count <= aw_stall_count + 1;
      if (read_valid && !mem_req.r_ready) r_stall_count <= r_stall_count + 1;
      if (mem_req.w_valid && !mem_rsp.w_ready) w_stall_count <= w_stall_count + 1;

      // Every address write sees at least one cycle of backpressure.  This is
      // independent of phase, so the coverage check cannot pass by coincidence.
      if (mem_req.aw_valid && !write_active && !write_resp_valid && !aw_wait_armed) begin
        aw_wait_armed <= 1'b1;
      end

      if (mem_req.ar_valid && mem_rsp.ar_ready) begin
        if (mem_req.ar.size > $clog2(StrbWidth)) $fatal(1, "oversized AXI read beat");
        read_active <= 1'b1;
        read_addr <= mem_req.ar.addr;
        read_size <= mem_req.ar.size;
        read_burst <= mem_req.ar.burst;
        read_beats_left <= int'(mem_req.ar.len) + 1;
        read_id <= mem_req.ar.id;
        ar_count <= ar_count + 1;
      end

      if (read_active && !read_valid && (memory_cycle[1:0] != 2'd2)) begin
        read_chan.id <= read_id;
        read_chan.data <= load_word(read_addr);
        read_chan.resp <= axi_pkg::RESP_OKAY;
        read_chan.last <= (read_beats_left == 1);
        read_chan.user <= '0;
        read_valid <= 1'b1;
      end

      if (read_valid && mem_req.r_ready) begin
        r_count <= r_count + 1;
        read_valid <= 1'b0;
        if (read_beats_left == 1) begin
          read_active <= 1'b0;
          read_beats_left <= 0;
        end else begin
          read_addr <= next_burst_addr(read_addr, read_size, read_burst);
          read_beats_left <= read_beats_left - 1;
        end
      end

      if (mem_req.aw_valid && mem_rsp.aw_ready) begin
        if (mem_req.aw.size > $clog2(StrbWidth)) $fatal(1, "oversized AXI write beat");
        write_active <= 1'b1;
        write_addr <= mem_req.aw.addr;
        write_size <= mem_req.aw.size;
        write_burst <= mem_req.aw.burst;
        write_beats_left <= int'(mem_req.aw.len) + 1;
        write_id <= mem_req.aw.id;
        aw_count <= aw_count + 1;
        aw_wait_armed <= 1'b0;
      end

      if (mem_req.w_valid && mem_rsp.w_ready) begin
        automatic addr_t base = aligned_word(write_addr);
        if (mem_req.w.last !== (write_beats_left == 1)) begin
          $fatal(1, "W.last=%0b with %0d beats remaining", mem_req.w.last, write_beats_left);
        end
        for (int unsigned lane = 0; lane < StrbWidth; lane++) begin
          if (mem_req.w.strb[lane]) memory[base + lane] = mem_req.w.data[lane*8 +: 8];
        end
        w_count <= w_count + 1;
        if (write_beats_left == 1) begin
          write_active <= 1'b0;
          write_beats_left <= 0;
          write_resp_chan.id <= write_id;
          write_resp_chan.resp <= axi_pkg::RESP_OKAY;
          write_resp_chan.user <= '0;
          write_resp_valid <= 1'b1;
        end else begin
          write_addr <= next_burst_addr(write_addr, write_size, write_burst);
          write_beats_left <= write_beats_left - 1;
        end
      end

      if (write_resp_valid && mem_req.b_ready) begin
        write_resp_valid <= 1'b0;
        b_count <= b_count + 1;
      end
    end
  end

  task automatic cfg_write(
    input addr_t address,
    input data_t data,
    input axi_pkg::size_t size,
    input strb_t strb
  );
    automatic bit aw_done = 0;
    automatic bit w_done = 0;
    @(negedge clk);
    cfg_req.aw = '0;
    cfg_req.aw.id = id_t'(1);
    cfg_req.aw.addr = address;
    cfg_req.aw.len = 0;
    cfg_req.aw.size = size;
    cfg_req.aw.burst = axi_pkg::BURST_INCR;
    cfg_req.aw_valid = 1'b1;
    cfg_req.w = '0;
    cfg_req.w.data = data;
    cfg_req.w.strb = strb;
    cfg_req.w.last = 1'b1;
    cfg_req.w_valid = 1'b1;
    cfg_req.b_ready = 1'b0;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (cfg_req.aw_valid && cfg_rsp.aw_ready) aw_done = 1;
      if (cfg_req.w_valid && cfg_rsp.w_ready) w_done = 1;
      @(negedge clk);
      if (aw_done) cfg_req.aw_valid = 1'b0;
      if (w_done) cfg_req.w_valid = 1'b0;
    end
    while (!cfg_rsp.b_valid) @(negedge clk);
    if (cfg_rsp.b.resp != axi_pkg::RESP_OKAY) $fatal(1, "config write 0x%0h failed", address);
    if (cfg_rsp.b.id != id_t'(1)) $fatal(1, "config write returned wrong AXI ID");
    cfg_req.b_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cfg_req.b_ready = 1'b0;
  endtask

  task automatic cfg_write64(input addr_t address, input logic [63:0] value);
    cfg_write(address, value, axi_pkg::size_t'(3), 8'hff);
  endtask

  task automatic cfg_write32(input addr_t address, input logic [31:0] value);
    if (address[2]) begin
      cfg_write(address, data_t'(value) << 32, axi_pkg::size_t'(2), 8'hf0);
    end else begin
      cfg_write(address, data_t'(value), axi_pkg::size_t'(2), 8'h0f);
    end
  endtask

  task automatic cfg_read32(input addr_t address, output logic [31:0] value);
    automatic bit ar_done = 0;
    automatic data_t read_data;
    @(negedge clk);
    cfg_req.ar = '0;
    cfg_req.ar.id = id_t'(2);
    cfg_req.ar.addr = address;
    cfg_req.ar.len = 0;
    cfg_req.ar.size = axi_pkg::size_t'(2);
    cfg_req.ar.burst = axi_pkg::BURST_INCR;
    cfg_req.ar_valid = 1'b1;
    cfg_req.r_ready = 1'b0;
    while (!ar_done) begin
      @(posedge clk);
      if (cfg_req.ar_valid && cfg_rsp.ar_ready) ar_done = 1;
      @(negedge clk);
      if (ar_done) cfg_req.ar_valid = 1'b0;
    end
    while (!cfg_rsp.r_valid) @(negedge clk);
    if (cfg_rsp.r.resp != axi_pkg::RESP_OKAY) $fatal(1, "config read 0x%0h failed", address);
    if (cfg_rsp.r.id != id_t'(2)) $fatal(1, "config read returned wrong AXI ID");
    if (!cfg_rsp.r.last) $fatal(1, "single-beat config read did not assert R.last");
    read_data = cfg_rsp.r.data;
    value = address[2] ? read_data[63:32] : read_data[31:0];
    cfg_req.r_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cfg_req.r_ready = 1'b0;
  endtask

  task automatic wait_done(input logic [31:0] transfer_id);
    automatic logic [31:0] done_id;
    for (int unsigned poll = 0; poll < 20000; poll++) begin
      cfg_read32(RegDoneId, done_id);
      if (done_id == transfer_id) return;
    end
    $fatal(1, "timed out waiting for DMA transfer %0d", transfer_id);
  endtask

  task automatic run_1d();
    localparam addr_t Src = 64'h8000_1000;
    localparam addr_t Dst = 64'h8000_4000;
    localparam int unsigned Length = 4096;
    localparam int unsigned Guard = 64;
    localparam logic [7:0] Sentinel = 8'ha5;
    automatic logic [31:0] transfer_id;
    automatic logic [31:0] status;
    automatic logic [31:0] done_while_active;
    automatic longint unsigned ar_before = ar_count;
    automatic longint unsigned aw_before = aw_count;
    automatic longint unsigned r_before = r_count;
    automatic longint unsigned w_before = w_count;
    automatic longint unsigned b_before = b_count;

    $display("[TB] Cheshire iDMA wrapper 1D: 0x%0h -> 0x%0h, %0d bytes", Src, Dst, Length);
    for (int unsigned i = 0; i < Length; i++) memory[Src + i] = 8'(i * 37 + 11);
    for (int unsigned i = 0; i < Length + 2*Guard; i++) memory[Dst - Guard + i] = Sentinel;

    cfg_write64(RegSrc, Src);
    cfg_write64(RegDst, Dst);
    cfg_write64(RegLength, Length);
    cfg_write32(RegConf, 32'h0);
    cfg_read32(RegNextId, transfer_id);
    if (transfer_id == 0) $fatal(1, "1D launch returned transfer ID zero");
    cfg_read32(RegStatus, status);
    cfg_read32(RegDoneId, done_while_active);
    if (status == 0 && done_while_active != transfer_id) begin
      $fatal(1, "1D status did not report busy after launch: done=%0d expected=%0d, r=%0d w=%0d of %0d expected beats",
             done_while_active, transfer_id, r_count-r_before, w_count-w_before,
             Length/StrbWidth);
    end
    wait_done(transfer_id);
    cfg_read32(RegStatus, status);
    if (status != 0) $fatal(1, "1D status remains busy: 0x%08x", status);

    for (int unsigned i = 0; i < Length; i++) begin
      automatic logic [7:0] expected = 8'(i * 37 + 11);
      if (load_byte(Dst + i) !== expected) begin
        $fatal(1, "1D payload mismatch at %0d: expected 0x%02x got 0x%02x",
               i, expected, load_byte(Dst + i));
      end
    end
    for (int unsigned i = 1; i <= Guard; i++) begin
      if (load_byte(Dst - i) !== Sentinel) $fatal(1, "1D destination underrun at -%0d", i);
      if (load_byte(Dst + Length + i - 1) !== Sentinel) begin
        $fatal(1, "1D destination overrun at +%0d", i);
      end
    end
    if ((ar_count - ar_before) == 0 || (aw_count - aw_before) == 0) begin
      $fatal(1, "1D copy emitted no AXI address traffic");
    end
    if ((r_count - r_before) != (w_count - w_before)) begin
      $fatal(1, "1D read/write beat mismatch: %0d/%0d",
             r_count - r_before, w_count - w_before);
    end
    if ((aw_count - aw_before) != (b_count - b_before)) begin
      $fatal(1, "1D write/response mismatch: %0d/%0d",
             aw_count - aw_before, b_count - b_before);
    end
    $display("[TB] 1D PASS: id=%0d ar=%0d aw=%0d r=%0d w=%0d b=%0d",
             transfer_id, ar_count-ar_before, aw_count-aw_before,
             r_count-r_before, w_count-w_before, b_count-b_before);
  endtask

  task automatic run_2d();
    localparam addr_t Src = 64'h8001_0000;
    localparam addr_t Dst = 64'h8001_8000;
    localparam int unsigned LineLength = 13;
    localparam int unsigned Reps = 7;
    localparam int unsigned SrcStride = 32;
    localparam int unsigned DstStride = 24;
    localparam int unsigned Guard = 32;
    localparam int unsigned Span = (Reps - 1) * DstStride + LineLength;
    localparam logic [7:0] Sentinel = 8'hc7;
    automatic logic [31:0] transfer_id;
    automatic logic [31:0] status;
    automatic logic [31:0] done_while_active;
    automatic longint unsigned ar_before = ar_count;
    automatic longint unsigned aw_before = aw_count;
    automatic longint unsigned r_before = r_count;
    automatic longint unsigned w_before = w_count;
    automatic longint unsigned b_before = b_count;

    $display("[TB] Cheshire iDMA wrapper 2D: %0d x %0d bytes, src stride %0d, dst stride %0d",
             Reps, LineLength, SrcStride, DstStride);
    for (int unsigned rep = 0; rep < Reps; rep++) begin
      for (int unsigned i = 0; i < LineLength; i++) begin
        memory[Src + rep*SrcStride + i] = 8'(8'h31 + rep*17 + i*3);
      end
    end
    for (int unsigned i = 0; i < Span + 2*Guard; i++) memory[Dst - Guard + i] = Sentinel;

    cfg_write64(RegSrc, Src);
    cfg_write64(RegDst, Dst);
    cfg_write64(RegLength, LineLength);
    cfg_write32(RegConf, ConfEnableNd);
    cfg_write64(RegSrcStride, SrcStride);
    cfg_write64(RegDstStride, DstStride);
    cfg_write64(RegReps, Reps);
    cfg_read32(RegNextId, transfer_id);
    if (transfer_id == 0) $fatal(1, "2D launch returned transfer ID zero");
    cfg_read32(RegStatus, status);
    cfg_read32(RegDoneId, done_while_active);
    if (status == 0 && done_while_active != transfer_id) begin
      $fatal(1, "2D status did not report busy after launch: done=%0d expected=%0d",
             done_while_active, transfer_id);
    end
    wait_done(transfer_id);
    cfg_read32(RegStatus, status);
    if (status != 0) $fatal(1, "2D status remains busy: 0x%08x", status);

    for (int unsigned offset = 0; offset < Span; offset++) begin
      automatic int unsigned lane = offset % DstStride;
      automatic int unsigned rep = offset / DstStride;
      automatic logic [7:0] expected = Sentinel;
      if (rep < Reps && lane < LineLength) expected = 8'(8'h31 + rep*17 + lane*3);
      if (load_byte(Dst + offset) !== expected) begin
        $fatal(1, "2D mismatch at offset %0d: expected 0x%02x got 0x%02x",
               offset, expected, load_byte(Dst + offset));
      end
    end
    for (int unsigned i = 1; i <= Guard; i++) begin
      if (load_byte(Dst - i) !== Sentinel) $fatal(1, "2D destination underrun at -%0d", i);
      if (load_byte(Dst + Span + i - 1) !== Sentinel) begin
        $fatal(1, "2D destination overrun at +%0d", i);
      end
    end
    if ((ar_count - ar_before) < Reps || (aw_count - aw_before) < Reps) begin
      $fatal(1, "2D copy emitted too few bursts: ar=%0d aw=%0d",
             ar_count-ar_before, aw_count-aw_before);
    end
    if ((r_count - r_before) != (w_count - w_before)) begin
      $fatal(1, "2D read/write beat mismatch: %0d/%0d",
             r_count-r_before, w_count-w_before);
    end
    if ((aw_count - aw_before) != (b_count - b_before)) begin
      $fatal(1, "2D write/response mismatch: %0d/%0d",
             aw_count-aw_before, b_count-b_before);
    end
    $display("[TB] 2D PASS: id=%0d ar=%0d aw=%0d r=%0d w=%0d b=%0d",
             transfer_id, ar_count-ar_before, aw_count-aw_before,
             r_count-r_before, w_count-w_before, b_count-b_before);
  endtask

  initial begin : test_sequence
    wait (rst_n);
    repeat (5) @(posedge clk);
    if (!$test$plusargs("only2d")) run_1d();
    if (DutTwoD && !$test$plusargs("only1d")) run_2d();
    if (ar_stall_count == 0 || aw_stall_count == 0 || w_stall_count == 0) begin
      $fatal(1, "backpressure coverage missing: ar=%0d aw=%0d w=%0d",
             ar_stall_count, aw_stall_count, w_stall_count);
    end
    $display("[TB] ALL PASS: exact Cheshire iDMA v0.6.4 wrapper; stalls ar=%0d aw=%0d r=%0d w=%0d",
             ar_stall_count, aw_stall_count, r_stall_count, w_stall_count);
    $finish;
  end

  initial begin : watchdog
    repeat (TimeoutCycles) @(posedge clk);
    $fatal(1, "simulation timeout after %0d cycles", TimeoutCycles);
  end

endmodule

