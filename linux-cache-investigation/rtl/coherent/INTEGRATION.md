# WT coherent reference: integration boundary

The bridge in this directory is lint-elaborated but is not connected to the
locked CVA6/Cheshire source.  Runtime coherency must not be claimed until the
following ports and assertions exist in a private RTL variant:

1. Add a dedicated `phase11_wt_dma_inval_if.cache` port at the CVA6 top level.
   In `cva6.sv` connect `inval_addr`, `inval_valid`, and `inval_ready` only to
   the existing `gen_cache_wt.i_cache_subsystem` invalidation path.  A generate
   gate must make enabling this interface with legacy WB or HPDcache an
   elaboration failure.
2. Add a cache-quiesce request/ack path.  Ack is legal only when no new CPU
   cache request can be accepted, the WT cache has no outstanding miss or
   memory transaction, and `dcache_commit_wbuffer_empty` is true.  Assert that
   no CPU cache request handshakes while quiesced.
3. Interpose `phase11_idma_wt_write_bridge` on the iDMA AXI **write** channels
   before Cheshire's crossbar; bypass its read channels unchanged.  The bridge
   supports one outstanding write burst, which matches the focused iDMA cell.
4. Keep the downstream B response asserted while the bridge quiesces and
   invalidates.  Return B to iDMA only after the last accepted invalidation.
   Assert that iDMA DONE cannot change while `pending_o` is set.
5. Connect and gate every bridge counter in the Phase 11 testbench.  A
   256-byte copy on the locked 16-byte-line configuration must produce exactly
   16 accepted lines, 1 quiesce request/ack, 16 invalidation request/acks, one
   delayed B, zero drops, and maximum FIFO occupancy 16.
6. Only that passing private cell may add `dma-coherent` to its private DT and
   disable `CONFIG_RISCV_CHESHIRE_CACHE_OPS`.  It must report zero Linux cache
   hooks.  The stale-source force-start and one-invalidation-drop controls are
   required before accepting the positive result.

The bridge does not create coherency for unmodified Cheshire and makes no
multicore claim.  A multicore successor must broadcast each invalidation and
collect one acknowledgement per core before releasing B.

