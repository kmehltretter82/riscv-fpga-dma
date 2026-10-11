// Deterministic, bounded AXI channel delay for the random-duration campaign.
module bounded_stream_delay #(
  parameter type payload_t = logic,
  parameter int unsigned MaxDelay = 7,
  parameter logic [15:0] Salt = 16'h1
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [31:0] seed_i,
  input  payload_t    payload_i,
  output logic        ready_o,
  input  logic        valid_i,
  output payload_t    payload_o,
  input  logic        ready_i,
  output logic        valid_o
);
  typedef enum logic [1:0] {Idle, Wait, Ready} state_e;
  state_e state_d, state_q;
  logic [15:0] lfsr_d, lfsr_q;
  logic [15:0] delay_d, delay_q;

  function automatic logic [15:0] lfsr_next(input logic [15:0] value);
    logic feedback;
    begin
      feedback = value[15] ^ value[13] ^ value[12] ^ value[10];
      lfsr_next = {value[14:0], feedback};
      if (lfsr_next == '0)
        lfsr_next = 16'h1;
    end
  endfunction

  assign payload_o = payload_i;

  always_comb begin
    state_d = state_q;
    lfsr_d = lfsr_q;
    delay_d = delay_q;
    ready_o = 1'b0;
    valid_o = 1'b0;
    unique case (state_q)
      Idle: begin
        if (valid_i) begin
          delay_d = lfsr_q & MaxDelay;
          lfsr_d = lfsr_next(lfsr_q);
          if ((lfsr_q & MaxDelay) == 0)
            state_d = Ready;
          else
            state_d = Wait;
        end
      end
      Wait: begin
        if (delay_q <= 1)
          state_d = Ready;
        else
          delay_d = delay_q - 1'b1;
      end
      Ready: begin
        valid_o = valid_i;
        ready_o = ready_i;
        if (valid_i && ready_i)
          state_d = Idle;
      end
      default: state_d = Idle;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Idle;
      lfsr_q <= ((seed_i[15:0] ^ seed_i[31:16] ^ Salt) == '0) ?
                16'h1 : (seed_i[15:0] ^ seed_i[31:16] ^ Salt);
      delay_q <= '0;
    end else begin
      state_q <= state_d;
      lfsr_q <= lfsr_d;
      delay_q <= delay_d;
    end
  end
endmodule

module axi_bounded_delayer #(
  parameter type aw_chan_t = logic,
  parameter type w_chan_t = logic,
  parameter type b_chan_t = logic,
  parameter type ar_chan_t = logic,
  parameter type r_chan_t = logic,
  parameter type axi_req_t = logic,
  parameter type axi_resp_t = logic,
  parameter int unsigned MaxDelay = 7
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [31:0] seed_i,
  input  axi_req_t    slv_req_i,
  output axi_resp_t   slv_resp_o,
  output axi_req_t    mst_req_o,
  input  axi_resp_t   mst_resp_i
);
  bounded_stream_delay #(.payload_t(aw_chan_t), .MaxDelay(MaxDelay), .Salt(16'h1357)) i_aw (
    .clk_i, .rst_ni, .seed_i, .payload_i(slv_req_i.aw),
    .ready_o(slv_resp_o.aw_ready), .valid_i(slv_req_i.aw_valid),
    .payload_o(mst_req_o.aw), .ready_i(mst_resp_i.aw_ready),
    .valid_o(mst_req_o.aw_valid));
  bounded_stream_delay #(.payload_t(w_chan_t), .MaxDelay(MaxDelay), .Salt(16'h2468)) i_w (
    .clk_i, .rst_ni, .seed_i, .payload_i(slv_req_i.w),
    .ready_o(slv_resp_o.w_ready), .valid_i(slv_req_i.w_valid),
    .payload_o(mst_req_o.w), .ready_i(mst_resp_i.w_ready),
    .valid_o(mst_req_o.w_valid));
  bounded_stream_delay #(.payload_t(ar_chan_t), .MaxDelay(MaxDelay), .Salt(16'h369c)) i_ar (
    .clk_i, .rst_ni, .seed_i, .payload_i(slv_req_i.ar),
    .ready_o(slv_resp_o.ar_ready), .valid_i(slv_req_i.ar_valid),
    .payload_o(mst_req_o.ar), .ready_i(mst_resp_i.ar_ready),
    .valid_o(mst_req_o.ar_valid));
  bounded_stream_delay #(.payload_t(b_chan_t), .MaxDelay(MaxDelay), .Salt(16'h5a5a)) i_b (
    .clk_i, .rst_ni, .seed_i, .payload_i(mst_resp_i.b),
    .ready_o(mst_req_o.b_ready), .valid_i(mst_resp_i.b_valid),
    .payload_o(slv_resp_o.b), .ready_i(slv_req_i.b_ready),
    .valid_o(slv_resp_o.b_valid));
  bounded_stream_delay #(.payload_t(r_chan_t), .MaxDelay(MaxDelay), .Salt(16'ha5a5)) i_r (
    .clk_i, .rst_ni, .seed_i, .payload_i(mst_resp_i.r),
    .ready_o(mst_req_o.r_ready), .valid_i(mst_resp_i.r_valid),
    .payload_o(slv_resp_o.r), .ready_i(slv_req_i.r_ready),
    .valid_o(slv_resp_o.r_valid));
endmodule
