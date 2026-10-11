// SPDX-License-Identifier: Apache-2.0
/*
 * One-outstanding-write AXI/iDMA coherence bridge for the proposed Phase 11
 * WT reference cell.
 *
 * The bridge forwards one AW/W burst, records every unique destination cache
 * line, withholds the downstream B response, quiesces the CPU cache, waits for
 * the WT write buffer to empty, invalidates all recorded lines, and only then
 * returns B to iDMA.  Since the iDMA completion follows B, completion cannot
 * precede the final invalidation.  Read channels bypass this write-only block.
 *
 * This source is concrete and synthesizable, but is not connected to locked
 * Cheshire.  See INTEGRATION.md for the missing CVA6/SoC ports and the exact
 * runtime acceptance boundary.
 */
module phase11_idma_wt_write_bridge #(
  parameter int unsigned AddrWidth   = 48,
  parameter int unsigned DataWidth   = 64,
  parameter int unsigned IdWidth     = 4,
  parameter int unsigned LineBytes   = 16,
  parameter int unsigned MaxLines    = 32,
  parameter bit          Enable      = 1'b1,
  parameter int unsigned CacheType   = 0,
  parameter int unsigned WtCacheType = 0
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,

  input  logic                   dma_aw_valid_i,
  output logic                   dma_aw_ready_o,
  input  logic [AddrWidth-1:0]   dma_aw_addr_i,
  input  logic [IdWidth-1:0]     dma_aw_id_i,
  input  logic [7:0]             dma_aw_len_i,
  input  logic [2:0]             dma_aw_size_i,
  input  logic [1:0]             dma_aw_burst_i,
  input  logic                   dma_w_valid_i,
  output logic                   dma_w_ready_o,
  input  logic [DataWidth-1:0]   dma_w_data_i,
  input  logic [DataWidth/8-1:0] dma_w_strb_i,
  input  logic                   dma_w_last_i,
  output logic                   dma_b_valid_o,
  input  logic                   dma_b_ready_i,
  output logic [IdWidth-1:0]     dma_b_id_o,
  output logic [1:0]             dma_b_resp_o,

  output logic                   mem_aw_valid_o,
  input  logic                   mem_aw_ready_i,
  output logic [AddrWidth-1:0]   mem_aw_addr_o,
  output logic [IdWidth-1:0]     mem_aw_id_o,
  output logic [7:0]             mem_aw_len_o,
  output logic [2:0]             mem_aw_size_o,
  output logic [1:0]             mem_aw_burst_o,
  output logic                   mem_w_valid_o,
  input  logic                   mem_w_ready_i,
  output logic [DataWidth-1:0]   mem_w_data_o,
  output logic [DataWidth/8-1:0] mem_w_strb_o,
  output logic                   mem_w_last_o,
  input  logic                   mem_b_valid_i,
  output logic                   mem_b_ready_o,
  input  logic [IdWidth-1:0]     mem_b_id_i,
  input  logic [1:0]             mem_b_resp_i,

  output logic                   cache_quiesce_req_o,
  input  logic                   cache_quiesce_ack_i,
  input  logic                   cache_wbuffer_empty_i,
  output logic [AddrWidth-1:0]   cache_inval_addr_o,
  output logic                   cache_inval_valid_o,
  input  logic                   cache_inval_ready_i,

  // Fault injection for the stale-destination negative control.  Suppressing
  // one selected request is allowed only in an explicitly negative run.
  input  logic                   fault_drop_inval_i,
  input  logic [$clog2(MaxLines)-1:0] fault_drop_index_i,

  output logic                   pending_o,
  output logic [31:0]            accepted_write_lines_o,
  output logic [31:0]            quiesce_requests_o,
  output logic [31:0]            quiesce_acks_o,
  output logic [31:0]            inval_requests_o,
  output logic [31:0]            inval_acks_o,
  output logic [31:0]            dropped_invalidations_o,
  output logic [31:0]            delayed_b_responses_o,
  output logic [$clog2(MaxLines+1)-1:0] max_line_occupancy_o
);

  localparam int unsigned LineShift = $clog2(LineBytes);
  localparam int unsigned LineCountWidth = $clog2(MaxLines + 1);

  typedef enum logic [2:0] {
    Idle, WriteData, WaitResponse, Quiesce, Invalidate, ReleaseResponse
  } state_t;

  state_t state_q, state_d;
  logic [AddrWidth-1:0] beat_addr_q, beat_addr_d;
  logic [8:0] beats_left_q, beats_left_d;
  logic [2:0] beat_size_q, beat_size_d;
  logic [AddrWidth-1:0] line_fifo_q [0:MaxLines-1];
  logic [AddrWidth-1:0] line_fifo_d [0:MaxLines-1];
  logic [LineCountWidth-1:0] line_count_q, line_count_d;
  logic [LineCountWidth-1:0] inval_index_q, inval_index_d;
  logic [AddrWidth-1:0] last_line_q, last_line_d;
  logic last_line_valid_q, last_line_valid_d;
  logic quiesce_counted_q, quiesce_counted_d;

  // A bad cache type is a compile/elaboration error, not a runtime warning.
  if (Enable && CacheType != WtCacheType) begin : gen_non_wt_is_illegal
    phase11_bridge_requires_wt_cache i_cache_type_must_be_wt();
  end

  initial begin
    if (DataWidth == 0 || DataWidth % 8 != 0)
      $fatal(1, "Phase 11 bridge requires a byte-addressable data width");
    if (LineBytes < DataWidth/8 || (LineBytes & (LineBytes - 1)) != 0)
      $fatal(1, "Phase 11 bridge requires a power-of-two line >= one beat");
    if (MaxLines < 2)
      $fatal(1, "Phase 11 bridge line FIFO is too small");
  end

  always_comb begin
    state_d = state_q;
    beat_addr_d = beat_addr_q;
    beats_left_d = beats_left_q;
    beat_size_d = beat_size_q;
    line_count_d = line_count_q;
    inval_index_d = inval_index_q;
    last_line_d = last_line_q;
    last_line_valid_d = last_line_valid_q;
    quiesce_counted_d = quiesce_counted_q;
    for (int unsigned i = 0; i < MaxLines; i++)
      line_fifo_d[i] = line_fifo_q[i];

    dma_aw_ready_o = 1'b0;
    dma_w_ready_o = 1'b0;
    dma_b_valid_o = 1'b0;
    dma_b_id_o = mem_b_id_i;
    dma_b_resp_o = mem_b_resp_i;
    mem_aw_valid_o = 1'b0;
    mem_aw_addr_o = dma_aw_addr_i;
    mem_aw_id_o = dma_aw_id_i;
    mem_aw_len_o = dma_aw_len_i;
    mem_aw_size_o = dma_aw_size_i;
    mem_aw_burst_o = dma_aw_burst_i;
    mem_w_valid_o = 1'b0;
    mem_w_data_o = dma_w_data_i;
    mem_w_strb_o = dma_w_strb_i;
    mem_w_last_o = dma_w_last_i;
    mem_b_ready_o = 1'b0;
    cache_quiesce_req_o = 1'b0;
    cache_inval_addr_o = '0;
    cache_inval_valid_o = 1'b0;

    unique case (state_q)
      Idle: begin
        mem_aw_valid_o = dma_aw_valid_i;
        dma_aw_ready_o = mem_aw_ready_i;
        if (dma_aw_valid_i && mem_aw_ready_i) begin
          beat_addr_d = dma_aw_addr_i;
          beats_left_d = {1'b0, dma_aw_len_i} + 9'd1;
          beat_size_d = dma_aw_size_i;
          line_count_d = '0;
          inval_index_d = '0;
          last_line_valid_d = 1'b0;
          quiesce_counted_d = 1'b0;
          if (dma_aw_burst_i != 2'b01)
            $fatal(1, "Phase 11 bridge supports incrementing bursts only");
          state_d = WriteData;
        end
      end

      WriteData: begin
        mem_w_valid_o = dma_w_valid_i;
        dma_w_ready_o = mem_w_ready_i;
        if (dma_w_valid_i && mem_w_ready_i) begin
          logic [AddrWidth-1:0] this_line;
          this_line = {beat_addr_q[AddrWidth-1:LineShift],
                       {LineShift{1'b0}}};
          if (!last_line_valid_q || this_line != last_line_q) begin
            if (line_count_q == MaxLines)
              $fatal(1, "Phase 11 invalidation FIFO overflow");
            else begin
              line_fifo_d[line_count_q] = this_line;
              line_count_d = line_count_q + 1'b1;
              last_line_d = this_line;
              last_line_valid_d = 1'b1;
            end
          end
          if ((beats_left_q == 1) != dma_w_last_i)
            $fatal(1, "Phase 11 AXI WLAST/AWLEN mismatch");
          beats_left_d = beats_left_q - 1'b1;
          beat_addr_d = beat_addr_q + ({{(AddrWidth-1){1'b0}}, 1'b1}
                                        << beat_size_q);
          if (dma_w_last_i)
            state_d = WaitResponse;
        end
      end

      WaitResponse: begin
        if (mem_b_valid_i)
          state_d = Quiesce;
      end

      Quiesce: begin
        cache_quiesce_req_o = 1'b1;
        if (cache_quiesce_ack_i && cache_wbuffer_empty_i) begin
          quiesce_counted_d = 1'b1;
          inval_index_d = '0;
          state_d = Invalidate;
        end
      end

      Invalidate: begin
        cache_quiesce_req_o = 1'b1;
        if (inval_index_q == line_count_q) begin
          state_d = ReleaseResponse;
        end else if (fault_drop_inval_i &&
                     inval_index_q == fault_drop_index_i) begin
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
        dma_b_valid_o = mem_b_valid_i;
        mem_b_ready_o = dma_b_ready_i;
        if (mem_b_valid_i && dma_b_ready_i)
          state_d = Idle;
      end

      default: state_d = Idle;
    endcase
  end

  assign pending_o = state_q != Idle;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Idle;
      beat_addr_q <= '0;
      beats_left_q <= '0;
      beat_size_q <= '0;
      line_count_q <= '0;
      inval_index_q <= '0;
      last_line_q <= '0;
      last_line_valid_q <= 1'b0;
      quiesce_counted_q <= 1'b0;
      accepted_write_lines_o <= '0;
      quiesce_requests_o <= '0;
      quiesce_acks_o <= '0;
      inval_requests_o <= '0;
      inval_acks_o <= '0;
      dropped_invalidations_o <= '0;
      delayed_b_responses_o <= '0;
      max_line_occupancy_o <= '0;
      for (int unsigned i = 0; i < MaxLines; i++)
        line_fifo_q[i] <= '0;
    end else begin
      state_q <= state_d;
      beat_addr_q <= beat_addr_d;
      beats_left_q <= beats_left_d;
      beat_size_q <= beat_size_d;
      line_count_q <= line_count_d;
      inval_index_q <= inval_index_d;
      last_line_q <= last_line_d;
      last_line_valid_q <= last_line_valid_d;
      quiesce_counted_q <= quiesce_counted_d;
      for (int unsigned i = 0; i < MaxLines; i++)
        line_fifo_q[i] <= line_fifo_d[i];

      if (state_q == WriteData && dma_w_valid_i && mem_w_ready_i &&
          (!last_line_valid_q ||
           {beat_addr_q[AddrWidth-1:LineShift], {LineShift{1'b0}}} !=
             last_line_q)) begin
        accepted_write_lines_o <= accepted_write_lines_o + 1'b1;
        if (line_count_q + 1'b1 > max_line_occupancy_o)
          max_line_occupancy_o <= line_count_q + 1'b1;
      end
      if (state_q == WaitResponse && mem_b_valid_i)
        quiesce_requests_o <= quiesce_requests_o + 1'b1;
      if (state_q == Quiesce && cache_quiesce_ack_i &&
          cache_wbuffer_empty_i && !quiesce_counted_q)
        quiesce_acks_o <= quiesce_acks_o + 1'b1;
      if (state_q == Invalidate && inval_index_q != line_count_q) begin
        if (fault_drop_inval_i && inval_index_q == fault_drop_index_i)
          dropped_invalidations_o <= dropped_invalidations_o + 1'b1;
        else if (cache_inval_ready_i) begin
          inval_requests_o <= inval_requests_o + 1'b1;
          inval_acks_o <= inval_acks_o + 1'b1;
        end
      end
      if (state_q == ReleaseResponse && mem_b_valid_i && dma_b_ready_i)
        delayed_b_responses_o <= delayed_b_responses_o + 1'b1;

      if (state_q != ReleaseResponse && dma_b_valid_o)
        $fatal(1, "Phase 11 released B with pending coherence work");
      if ((state_q == Quiesce || state_q == Invalidate ||
           state_q == ReleaseResponse) && !mem_b_valid_i)
        $fatal(1, "downstream AXI B disappeared while withheld");
    end
  end

endmodule

