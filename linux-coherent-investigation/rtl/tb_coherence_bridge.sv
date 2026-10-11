`timescale 1ns/1ps

module tb_coherence_bridge;
  localparam int AddrWidth = 48;
  localparam int DataWidth = 64;
  localparam int IdWidth = 4;
  localparam int LineBytes = 16;
  localparam int MaxLines = 8;
  localparam logic [7:0] OLD_SRC = 8'h31;
  localparam logic [7:0] NEW_SRC = 8'ha7;
  localparam logic [7:0] OLD_DST = 8'h5c;

  typedef struct packed {
    logic [IdWidth-1:0] id;
    logic [AddrWidth-1:0] addr;
    logic [7:0] len;
    logic [2:0] size;
    logic [1:0] burst;
  } addr_chan_t;
  typedef struct packed {
    logic [DataWidth-1:0] data;
    logic [DataWidth/8-1:0] strb;
    logic last;
  } w_chan_t;
  typedef struct packed {
    logic [IdWidth-1:0] id;
    logic [1:0] resp;
  } b_chan_t;
  typedef struct packed {
    logic [IdWidth-1:0] id;
    logic [DataWidth-1:0] data;
    logic [1:0] resp;
    logic last;
  } r_chan_t;
  typedef struct packed {
    addr_chan_t aw;
    logic aw_valid;
    w_chan_t w;
    logic w_valid;
    logic b_ready;
    addr_chan_t ar;
    logic ar_valid;
    logic r_ready;
  } axi_req_t;
  typedef struct packed {
    logic aw_ready;
    logic w_ready;
    b_chan_t b;
    logic b_valid;
    logic ar_ready;
    r_chan_t r;
    logic r_valid;
  } axi_rsp_t;

  logic clk = 0;
  logic rst_n = 0;
  axi_req_t dma_req, mem_req;
  axi_rsp_t dma_rsp, mem_rsp;
  logic cache_quiesce_req, cache_quiesce_ack;
  logic [AddrWidth-1:0] cache_inval_addr;
  logic cache_inval_valid, cache_inval_ready;
  logic fault_skip_source_drain, fault_drop_inval;
  logic [$clog2(MaxLines)-1:0] fault_drop_index;
  logic pending;
  logic [31:0] drain_req, drain_ack, write_lines;
  logic [31:0] quiesce_req, quiesce_ack_count;
  logic [31:0] inval_req, inval_ack, dropped_inval, delayed_b;
  logic [31:0] completion_pending;

  logic mem_b_valid;
  logic [7:0] source_memory, dma_source_snapshot, destination_memory;
  logic source_write_pending;
  logic [1:0] destination_cache_valid;
  logic [2:0] quiesce_cycles;

  always #5 clk = ~clk;

  phase11_wt_coherence_bridge #(
    .AddrWidth(AddrWidth), .LineBytes(LineBytes), .MaxLines(MaxLines),
    .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t)
  ) i_bridge (
    .clk_i(clk), .rst_ni(rst_n),
    .dma_req_i(dma_req), .dma_rsp_o(dma_rsp),
    .mem_req_o(mem_req), .mem_rsp_i(mem_rsp),
    .cache_quiesce_req_o(cache_quiesce_req),
    .cache_quiesce_ack_i(cache_quiesce_ack),
    .cache_inval_addr_o(cache_inval_addr),
    .cache_inval_valid_o(cache_inval_valid),
    .cache_inval_ready_i(cache_inval_ready),
    .fault_skip_source_drain_i(fault_skip_source_drain),
    .fault_drop_inval_i(fault_drop_inval),
    .fault_drop_index_i(fault_drop_index),
    .pending_o(pending),
    .source_drain_requests_o(drain_req),
    .source_drain_acks_o(drain_ack),
    .quiesce_requests_o(quiesce_req),
    .quiesce_acks_o(quiesce_ack_count),
    .accepted_write_lines_o(write_lines),
    .inval_requests_o(inval_req), .inval_acks_o(inval_ack),
    .dropped_invalidations_o(dropped_inval),
    .delayed_b_responses_o(delayed_b),
    .completion_with_pending_o(completion_pending)
  );

  always_comb begin
    mem_rsp = '0;
    mem_rsp.aw_ready = 1'b1;
    mem_rsp.w_ready = 1'b1;
    mem_rsp.ar_ready = 1'b1;
    mem_rsp.b_valid = mem_b_valid;
    mem_rsp.b.id = '0;
    mem_rsp.b.resp = 2'b00;
    cache_inval_ready = 1'b1;
  end

  // A deterministic WT-cache abstraction.  NEW_SRC initially sits in its
  // write buffer while RAM retains OLD_SRC.  A quiesce acknowledgement is
  // legal only after that write has drained.  Destination lines start valid
  // with OLD_DST and become RAM-visible only when invalidated.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cache_quiesce_ack <= 1'b0;
      quiesce_cycles <= '0;
      source_memory <= OLD_SRC;
      source_write_pending <= 1'b1;
      dma_source_snapshot <= '0;
      destination_memory <= OLD_DST;
      destination_cache_valid <= 2'b11;
      mem_b_valid <= 1'b0;
    end else begin
      if (cache_quiesce_req) begin
        if (!cache_quiesce_ack) begin
          quiesce_cycles <= quiesce_cycles + 1'b1;
          if (quiesce_cycles == 2) begin
            if (source_write_pending) begin
              source_memory <= NEW_SRC;
              source_write_pending <= 1'b0;
            end
            cache_quiesce_ack <= 1'b1;
          end
        end
      end else begin
        cache_quiesce_ack <= 1'b0;
        quiesce_cycles <= '0;
      end

      if (mem_req.ar_valid && mem_rsp.ar_ready)
        dma_source_snapshot <= source_memory;
      if (mem_req.w_valid && mem_rsp.w_ready)
        destination_memory <= dma_source_snapshot;
      if (mem_req.w_valid && mem_rsp.w_ready && mem_req.w.last)
        mem_b_valid <= 1'b1;
      if (mem_b_valid && mem_req.b_ready)
        mem_b_valid <= 1'b0;

      if (cache_inval_valid && cache_inval_ready) begin
        if (cache_inval_addr[4])
          destination_cache_valid[1] <= 1'b0;
        else
          destination_cache_valid[0] <= 1'b0;
      end
    end
  end

  task automatic reset_case(input logic skip_drain, input logic drop_inval);
    dma_req = '0;
    fault_skip_source_drain = skip_drain;
    fault_drop_inval = drop_inval;
    fault_drop_index = 1;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
  endtask

  task automatic run_transfer;
    dma_req = '0;
    dma_req.b_ready = 1'b1;
    dma_req.r_ready = 1'b1;
    dma_req.ar.addr = 48'h1000;
    dma_req.ar.len = 3;
    dma_req.ar.size = 3;
    dma_req.ar.burst = 2'b01;
    dma_req.ar_valid = 1'b1;
    dma_req.aw.addr = 48'h2000;
    dma_req.aw.len = 3;
    dma_req.aw.size = 3;
    dma_req.aw.burst = 2'b01;
    dma_req.aw_valid = 1'b1;
    while (!(dma_rsp.ar_ready && dma_rsp.aw_ready)) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    dma_req.ar_valid = 1'b0;
    dma_req.aw_valid = 1'b0;

    for (int beat = 0; beat < 4; beat++) begin
      dma_req.w.data = {8{dma_source_snapshot}};
      dma_req.w.strb = '1;
      dma_req.w.last = beat == 3;
      dma_req.w_valid = 1'b1;
      while (!dma_rsp.w_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      dma_req.w_valid = 1'b0;
    end

    while (!dma_rsp.b_valid) @(negedge clk);
    @(posedge clk);
    @(negedge clk);
    dma_req.b_ready = 1'b0;
    repeat (2) @(posedge clk);
  endtask

  function automatic logic [7:0] cpu_destination_line(input int line);
    return destination_cache_valid[line] ? OLD_DST : destination_memory;
  endfunction

  initial begin
    // Positive: both coherency legs active.
    reset_case(1'b0, 1'b0);
    run_transfer();
    if (dma_source_snapshot != NEW_SRC ||
        cpu_destination_line(0) != NEW_SRC ||
        cpu_destination_line(1) != NEW_SRC ||
        drain_req != 1 || drain_ack != 1 || write_lines != 2 ||
        quiesce_req != 1 || quiesce_ack_count != 1 ||
        inval_req != 2 || inval_ack != 2 || dropped_inval != 0 ||
        delayed_b != 1 || completion_pending != 0)
      $fatal(1, "positive coherence gate failed");
    $display("COHERENCE_RECORD run=positive source_ram=new_src dma_read=new_src destination_cpu=new_src source_drain=1/1 quiesce=1/1 inval=2/2 dropped=0 delayed_b=1 completion_pending=0");

    // Negative source leg: DMA starts before WT write-buffer drain.
    reset_case(1'b1, 1'b0);
    run_transfer();
    if (dma_source_snapshot != OLD_SRC ||
        cpu_destination_line(0) != OLD_SRC ||
        cpu_destination_line(1) != OLD_SRC ||
        drain_req != 0 || drain_ack != 0 || write_lines != 2 ||
        quiesce_req != 1 || quiesce_ack_count != 1 ||
        inval_req != 2 || inval_ack != 2 || dropped_inval != 0 ||
        delayed_b != 1 || completion_pending != 0)
      $fatal(1, "stale-source negative control failed");
    $display("COHERENCE_RECORD run=stale-source source_ram=old_src dma_read=old_src destination_cpu=old_src source_drain=0/0 quiesce=1/1 inval=2/2 dropped=0 delayed_b=1 completion_pending=0");

    // Negative destination leg: one cached line survives DMA completion.
    reset_case(1'b0, 1'b1);
    run_transfer();
    if (dma_source_snapshot != NEW_SRC ||
        cpu_destination_line(0) != NEW_SRC ||
        cpu_destination_line(1) != OLD_DST ||
        drain_req != 1 || drain_ack != 1 || write_lines != 2 ||
        quiesce_req != 1 || quiesce_ack_count != 1 ||
        inval_req != 1 || inval_ack != 1 || dropped_inval != 1 ||
        delayed_b != 1 || completion_pending != 0)
      $fatal(1, "stale-destination negative control failed");
    $display("COHERENCE_RECORD run=stale-destination source_ram=new_src dma_read=new_src destination_cpu=old_dst source_drain=1/1 quiesce=1/1 inval=1/1 dropped=1 delayed_b=1 completion_pending=0");

    $display("PHASE11-COHERENCE-BRIDGE-PASS");
    $finish;
  end

  initial begin
    repeat (500) @(posedge clk);
    $fatal(1, "bridge regression timeout");
  end
endmodule

