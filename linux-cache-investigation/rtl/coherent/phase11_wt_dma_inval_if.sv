// SPDX-License-Identifier: Apache-2.0
// Dedicated Phase 11 WT-cache invalidation interface.  This deliberately does
// not reuse CVXIF: device coherence and accelerator requests have different
// ownership and quiescence rules.
interface phase11_wt_dma_inval_if #(
  parameter int unsigned AddrWidth = 48
);
  logic                 quiesce_req;
  logic                 quiesce_ack;
  logic                 wbuffer_empty;
  logic [AddrWidth-1:0] inval_addr;
  logic                 inval_valid;
  logic                 inval_ready;

  modport bridge (
    output quiesce_req, inval_addr, inval_valid,
    input  quiesce_ack, wbuffer_empty, inval_ready
  );
  modport cache (
    input  quiesce_req, inval_addr, inval_valid,
    output quiesce_ack, wbuffer_empty, inval_ready
  );
endinterface

