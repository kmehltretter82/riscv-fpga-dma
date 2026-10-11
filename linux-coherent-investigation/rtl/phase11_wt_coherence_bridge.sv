// SPDX-License-Identifier: Apache-2.0
/*
 * Focused single-write-burst iDMA/CVA6-WT coherence bridge.
 *
 * Linux owns the buffers while a transfer is active.  Before the first DMA
 * memory request is released, the bridge stalls the WT cache and waits for an
 * acknowledgement that includes an empty CPU write buffer.  It then keeps the
 * cache quiesced through the transfer.  The downstream write response is held
 * until every destination cache line has been invalidated, so iDMA completion
 * cannot become visible early.
 *
 * This focused bridge deliberately accepts one AXI write burst at a time.  A
 * second AW before the prior B is returned is an assertion failure.  Read data
 * and responses pass through after the source drain.
 */
module phase11_wt_coherence_bridge #(
  parameter int unsigned AddrWidth = 48,
  parameter int unsigned LineBytes = 16,
  parameter int unsigned MaxLines  = 32,
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  axi_req_t   dma_req_i,
  output axi_rsp_t   dma_rsp_o,
  output axi_req_t   mem_req_o,
  input  axi_rsp_t   mem_rsp_i,

  output logic                 cache_quiesce_req_o,
  input  logic                 cache_quiesce_ack_i,
  output logic [AddrWidth-1:0] cache_inval_addr_o,
  output logic                 cache_inval_valid_o,
  input  logic                 cache_inval_ready_i,

  input  logic fault_skip_source_drain_i,
  input  logic fault_drop_inval_i,
  input  logic [$clog2(MaxLines)-1:0] fault_drop_index_i,

  output logic        pending_o,
  output logic [31:0] source_drain_requests_o,
  output logic [31:0] source_drain_acks_o,
  output logic [31:0] quiesce_requests_o,
  output logic [31:0] quiesce_acks_o,
  output logic [31:0] accepted_write_lines_o,
  output logic [31:0] inval_requests_o,
  output logic [31:0] inval_acks_o,
  output logic [31:0] dropped_invalidations_o,
  output logic [31:0] delayed_b_responses_o,
  output logic [31:0] completion_with_pending_o
);

  localparam int unsigned LineShift = $clog2(LineBytes);
  localparam int unsigned CountWidth = $clog2(MaxLines + 1);

  typedef enum logic [2:0] {
    Idle, DrainBefore, Transfer, DrainAfter, Invalidate, ReleaseResponse
  } state_t;

  state_t state_q, state_d;
  logic aw_seen_q, aw_seen_d;
  logic [AddrWidth-1:0] beat_addr_q, beat_addr_d;
  logic [8:0] beats_left_q, beats_left_d;
  logic [2:0] beat_size_q, beat_size_d;
  logic [AddrWidth-1:0] line_fifo_q [0:MaxLines-1];
  logic [AddrWidth-1:0] line_fifo_d [0:MaxLines-1];
  logic [CountWidth-1:0] line_count_q, line_count_d;
  logic [CountWidth-1:0] inval_index_q, inval_index_d;
  logic [AddrWidth-1:0] last_line_q, last_line_d;
  logic last_line_valid_q, last_line_valid_d;
  logic skip_drain_q, skip_drain_d;
  logic drop_inval_q, drop_inval_d;
  logic [$clog2(MaxLines)-1:0] drop_index_q, drop_index_d;

  initial begin
    if (LineBytes < 2 || (LineBytes & (LineBytes - 1)) != 0)
      $fatal(1, "coherence bridge requires a power-of-two cache line");
    if (MaxLines < 2)
      $fatal(1, "coherence bridge line FIFO is too small");
  end

  always_comb begin
    state_d = state_q;
    aw_seen_d = aw_seen_q;
    beat_addr_d = beat_addr_q;
    beats_left_d = beats_left_q;
    beat_size_d = beat_size_q;
    line_count_d = line_count_q;
    inval_index_d = inval_index_q;
    last_line_d = last_line_q;
    last_line_valid_d = last_line_valid_q;
    skip_drain_d = skip_drain_q;
    drop_inval_d = drop_inval_q;
    drop_index_d = drop_index_q;
    for (int unsigned i = 0; i < MaxLines; i++)
      line_fifo_d[i] = line_fifo_q[i];

    mem_req_o = '0;
    dma_rsp_o = '0;
    cache_quiesce_req_o = 1'b0;
    cache_inval_addr_o = '0;
    cache_inval_valid_o = 1'b0;

    unique case (state_q)
      Idle: begin
        if (dma_req_i.ar_valid || dma_req_i.aw_valid) begin
          skip_drain_d = fault_skip_source_drain_i;
          drop_inval_d = fault_drop_inval_i;
          drop_index_d = fault_drop_index_i;
          line_count_d = '0;
          inval_index_d = '0;
          last_line_valid_d = 1'b0;
          aw_seen_d = 1'b0;
          state_d = fault_skip_source_drain_i ? Transfer : DrainBefore;
        end
      end

      DrainBefore: begin
        cache_quiesce_req_o = 1'b1;
        if (cache_quiesce_ack_i)
          state_d = Transfer;
      end

      Transfer: begin
        cache_quiesce_req_o = !skip_drain_q;
        mem_req_o = dma_req_i;
        dma_rsp_o = mem_rsp_i;
        // Withhold B until destination invalidation has completed.
        dma_rsp_o.b_valid = 1'b0;
        mem_req_o.b_ready = 1'b0;
        mem_req_o.aw_valid = dma_req_i.aw_valid && !aw_seen_q;
        dma_rsp_o.aw_ready = mem_rsp_i.aw_ready && !aw_seen_q;
        // AXI permits AW and the first W beat in the same cycle.  Accept AW
        // first so the line recorder always has a stable burst address.
        mem_req_o.w_valid = dma_req_i.w_valid && aw_seen_q;
        dma_rsp_o.w_ready = mem_rsp_i.w_ready && aw_seen_q;

        if (dma_req_i.aw_valid && mem_rsp_i.aw_ready && !aw_seen_q) begin
          if (dma_req_i.aw.burst != 2'b01)
            $fatal(1, "coherence bridge supports INCR bursts only");
          aw_seen_d = 1'b1;
          beat_addr_d = dma_req_i.aw.addr;
          beats_left_d = {1'b0, dma_req_i.aw.len} + 9'd1;
          beat_size_d = dma_req_i.aw.size;
        end
        if (dma_req_i.w_valid && mem_rsp_i.w_ready && aw_seen_q) begin
          logic [AddrWidth-1:0] this_line;
          if (!aw_seen_q)
            $fatal(1, "W accepted before AW");
          this_line = {beat_addr_q[AddrWidth-1:LineShift],
                       {LineShift{1'b0}}};
          if (!last_line_valid_q || this_line != last_line_q) begin
            if (line_count_q == MaxLines)
              $fatal(1, "coherence invalidation FIFO overflow");
            line_fifo_d[line_count_q] = this_line;
            line_count_d = line_count_q + 1'b1;
            last_line_d = this_line;
            last_line_valid_d = 1'b1;
          end
          beats_left_d = beats_left_q - 1'b1;
          beat_addr_d = beat_addr_q + ({{(AddrWidth-1){1'b0}}, 1'b1}
                                        << beat_size_q);
        end
        if (mem_rsp_i.b_valid) begin
          if (!aw_seen_q || beats_left_q != 0)
            $fatal(1, "B arrived before complete write burst");
          state_d = skip_drain_q ? DrainAfter : Invalidate;
        end
      end

      DrainAfter: begin
        cache_quiesce_req_o = 1'b1;
        if (cache_quiesce_ack_i)
          state_d = Invalidate;
      end

      Invalidate: begin
        cache_quiesce_req_o = 1'b1;
        if (inval_index_q == line_count_q) begin
          state_d = ReleaseResponse;
        end else if (drop_inval_q && inval_index_q == drop_index_q) begin
          inval_index_d = inval_index_q + 1'b1;
        end else begin
          cache_inval_addr_o = line_fifo_q[inval_index_q];
          cache_inval_valid_o = 1'b1;
          if (cache_inval_ready_i)
            inval_index_d = inval_index_q + 1'b1;
        end
      end

      ReleaseResponse: begin
        cache_quiesce_req_o = 1'b1;
        dma_rsp_o.b_valid = mem_rsp_i.b_valid;
        dma_rsp_o.b = mem_rsp_i.b;
        mem_req_o.b_ready = dma_req_i.b_ready;
        if (mem_rsp_i.b_valid && dma_req_i.b_ready)
          state_d = Idle;
      end

      default: state_d = Idle;
    endcase
  end

  assign pending_o = state_q != Idle;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Idle;
      aw_seen_q <= 1'b0;
      beat_addr_q <= '0;
      beats_left_q <= '0;
      beat_size_q <= '0;
      line_count_q <= '0;
      inval_index_q <= '0;
      last_line_q <= '0;
      last_line_valid_q <= 1'b0;
      skip_drain_q <= 1'b0;
      drop_inval_q <= 1'b0;
      drop_index_q <= '0;
      source_drain_requests_o <= '0;
      source_drain_acks_o <= '0;
      quiesce_requests_o <= '0;
      quiesce_acks_o <= '0;
      accepted_write_lines_o <= '0;
      inval_requests_o <= '0;
      inval_acks_o <= '0;
      dropped_invalidations_o <= '0;
      delayed_b_responses_o <= '0;
      completion_with_pending_o <= '0;
      for (int unsigned i = 0; i < MaxLines; i++)
        line_fifo_q[i] <= '0;
    end else begin
      state_q <= state_d;
      aw_seen_q <= aw_seen_d;
      beat_addr_q <= beat_addr_d;
      beats_left_q <= beats_left_d;
      beat_size_q <= beat_size_d;
      line_count_q <= line_count_d;
      inval_index_q <= inval_index_d;
      last_line_q <= last_line_d;
      last_line_valid_q <= last_line_valid_d;
      skip_drain_q <= skip_drain_d;
      drop_inval_q <= drop_inval_d;
      drop_index_q <= drop_index_d;
      for (int unsigned i = 0; i < MaxLines; i++)
        line_fifo_q[i] <= line_fifo_d[i];

      if (state_q == Idle && (dma_req_i.ar_valid || dma_req_i.aw_valid) &&
          !fault_skip_source_drain_i)
        source_drain_requests_o <= source_drain_requests_o + 1'b1;
      if (state_q == DrainBefore && cache_quiesce_ack_i)
        source_drain_acks_o <= source_drain_acks_o + 1'b1;
      // Every burst has exactly one quiescent boundary.  The positive path
      // drains before memory traffic; the stale-source control deliberately
      // moves that boundary behind the captured source data so destination
      // invalidation can still be tested safely.
      if ((state_q == Idle && (dma_req_i.ar_valid || dma_req_i.aw_valid) &&
           !fault_skip_source_drain_i) ||
          (state_q == Transfer && mem_rsp_i.b_valid && skip_drain_q))
        quiesce_requests_o <= quiesce_requests_o + 1'b1;
      if ((state_q == DrainBefore || state_q == DrainAfter) &&
          cache_quiesce_ack_i)
        quiesce_acks_o <= quiesce_acks_o + 1'b1;
      if (state_q == Transfer && dma_req_i.w_valid && mem_rsp_i.w_ready &&
          aw_seen_q &&
          (!last_line_valid_q ||
           {beat_addr_q[AddrWidth-1:LineShift], {LineShift{1'b0}}} !=
             last_line_q))
        accepted_write_lines_o <= accepted_write_lines_o + 1'b1;
      if (state_q == Transfer && dma_req_i.w_valid && mem_rsp_i.w_ready &&
          aw_seen_q && ((beats_left_q == 1) != dma_req_i.w.last))
        $fatal(1, "AXI WLAST/AWLEN mismatch");
      if (state_q == Invalidate && inval_index_q != line_count_q) begin
        if (drop_inval_q && inval_index_q == drop_index_q)
          dropped_invalidations_o <= dropped_invalidations_o + 1'b1;
        else if (cache_inval_ready_i) begin
          inval_requests_o <= inval_requests_o + 1'b1;
          inval_acks_o <= inval_acks_o + 1'b1;
        end
      end
      if (state_q == ReleaseResponse && mem_rsp_i.b_valid && dma_req_i.b_ready)
        delayed_b_responses_o <= delayed_b_responses_o + 1'b1;
      if (dma_rsp_o.b_valid && state_q != ReleaseResponse)
        completion_with_pending_o <= completion_with_pending_o + 1'b1;

      if ((state_q == DrainAfter || state_q == Invalidate ||
           state_q == ReleaseResponse) && !mem_rsp_i.b_valid)
        $fatal(1, "downstream B disappeared while withheld");
      if (dma_rsp_o.b_valid && state_q != ReleaseResponse)
        $fatal(1, "DMA completion escaped pending coherence work");
    end
  end

endmodule
