# Open Verilator Cheshire/CVA6 iDMA harness

This harness elaborates the production Cheshire SoC at commit `292d2c0` with
its locked CVA6 and iDMA v0.6.4 dependencies.  CVA6 boots a small bare-metal
program from a cached external AXI region.  Its DMA buffers use a distinct
noncacheable region on the same AXI memory model.

The firmware programs Cheshire's real iDMA register frontend and verifies 30
guarded jobs: 21 one-dimensional transfers around byte, 64-bit beat, likely
burst and 4 KiB boundaries; eight packed or gapped two-dimensional transfers;
and one nonblocking transfer with concurrent CVA6 traffic.  Source contents,
destination payloads, row gaps and both destination guards are checked.  The
testbench independently counts frontend issue/retire events, backend busy
cycles, AXI handshakes and wait cycles.

`./run.sh baseline` builds once and executes three controls: normal timing,
fixed delays on all five AXI channels, and the delayed case with a full SoC
reset injected while iDMA is busy.  `axi_sim_mem_reset.sv` is a retained
derivative of the locked AXI simulation memory.  It clears in-flight protocol
queues on every reset while preserving the loaded byte array.  This is needed
because upstream `axi_sim_mem` starts its channel processes only after the
first reset and is not a repeated-reset model.

The locked Bender dependency checkouts are disposable and are not retained in
this workspace.  Restore them once before the next build:

```sh
cd /home/karl/linux-work/dmadebug2/riscv-fpga-dma
BENDER_DB_DIR=/home/karl/linux-work/dmadebug2/riscv-fpga-dma/idma/.bender/git/db \
  .tools/bin/bender -d cheshire checkout --no-progress
```

This uses Cheshire's retained `Bender.lock`; the runner then sets
`BENDER_LOCAL=true` so a campaign cannot silently change dependency revisions.

```sh
cd /home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire-soc-vlt
./run.sh baseline
./run.sh data-fault
```

The fault mode creates a disposable iDMA v0.6.4 worktree and corrupts one
valid bit on a final write beat under the delayed AXI timing.  It succeeds
only if CVA6 reports exact error `0x1001` on the first one-byte transfer.  Both
modes rebuild from empty generated object directories.
