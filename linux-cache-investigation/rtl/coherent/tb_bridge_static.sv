`timescale 1ns/1ps
module tb_bridge_static;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  phase11_idma_wt_write_bridge #(
    .AddrWidth(48), .DataWidth(64), .IdWidth(4), .LineBytes(16),
    .MaxLines(32), .Enable(1'b1), .CacheType(0), .WtCacheType(0)
  ) i_bridge (
    .clk_i(clk), .rst_ni(rst_n),
    .dma_aw_valid_i('0), .dma_aw_ready_o(), .dma_aw_addr_i('0),
    .dma_aw_id_i('0), .dma_aw_len_i('0), .dma_aw_size_i(3),
    .dma_aw_burst_i(2'b01), .dma_w_valid_i('0), .dma_w_ready_o(),
    .dma_w_data_i('0), .dma_w_strb_i('0), .dma_w_last_i('0),
    .dma_b_valid_o(), .dma_b_ready_i('0), .dma_b_id_o(), .dma_b_resp_o(),
    .mem_aw_valid_o(), .mem_aw_ready_i('0), .mem_aw_addr_o(),
    .mem_aw_id_o(), .mem_aw_len_o(), .mem_aw_size_o(), .mem_aw_burst_o(),
    .mem_w_valid_o(), .mem_w_ready_i('0), .mem_w_data_o(),
    .mem_w_strb_o(), .mem_w_last_o(), .mem_b_valid_i('0),
    .mem_b_ready_o(), .mem_b_id_i('0), .mem_b_resp_i('0),
    .cache_quiesce_req_o(), .cache_quiesce_ack_i('0),
    .cache_wbuffer_empty_i('0), .cache_inval_addr_o(),
    .cache_inval_valid_o(), .cache_inval_ready_i('0),
    .fault_drop_inval_i('0), .fault_drop_index_i('0), .pending_o(),
    .accepted_write_lines_o(), .quiesce_requests_o(), .quiesce_acks_o(),
    .inval_requests_o(), .inval_acks_o(), .dropped_invalidations_o(),
    .delayed_b_responses_o(), .max_line_occupancy_o()
  );
endmodule

module tb_bridge_bad_cache_type;
  logic [47:0] a;
  phase11_idma_wt_write_bridge #(
    .AddrWidth(48), .DataWidth(64), .IdWidth(4), .LineBytes(16),
    .MaxLines(32), .Enable(1'b1), .CacheType(1), .WtCacheType(0)
  ) i_bridge (
    .clk_i('0), .rst_ni('0),
    .dma_aw_valid_i('0), .dma_aw_ready_o(), .dma_aw_addr_i('0),
    .dma_aw_id_i('0), .dma_aw_len_i('0), .dma_aw_size_i('0),
    .dma_aw_burst_i('0), .dma_w_valid_i('0), .dma_w_ready_o(),
    .dma_w_data_i('0), .dma_w_strb_i('0), .dma_w_last_i('0),
    .dma_b_valid_o(), .dma_b_ready_i('0), .dma_b_id_o(), .dma_b_resp_o(),
    .mem_aw_valid_o(), .mem_aw_ready_i('0), .mem_aw_addr_o(a),
    .mem_aw_id_o(), .mem_aw_len_o(), .mem_aw_size_o(), .mem_aw_burst_o(),
    .mem_w_valid_o(), .mem_w_ready_i('0), .mem_w_data_o(),
    .mem_w_strb_o(), .mem_w_last_o(), .mem_b_valid_i('0),
    .mem_b_ready_o(), .mem_b_id_i('0), .mem_b_resp_i('0),
    .cache_quiesce_req_o(), .cache_quiesce_ack_i('0),
    .cache_wbuffer_empty_i('0), .cache_inval_addr_o(),
    .cache_inval_valid_o(), .cache_inval_ready_i('0),
    .fault_drop_inval_i('0), .fault_drop_index_i('0), .pending_o(),
    .accepted_write_lines_o(), .quiesce_requests_o(), .quiesce_acks_o(),
    .inval_requests_o(), .inval_acks_o(), .dropped_invalidations_o(),
    .delayed_b_responses_o(), .max_line_occupancy_o()
  );
endmodule

