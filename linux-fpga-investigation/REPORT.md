# Linux on simulated Cheshire with kernel-visible iDMA

Date: 2026-10-11 UTC

> **Current status:** The early 60/300-second result documented below has been
> superseded. Instrumented runs subsequently proved OpenSBI and Linux 7.2
> execution in the complete model, and source review established that the
> selected legacy CVA6 WB cache writes back *and invalidates* on FENCE. The
> current payload uses an explicit noncoherent Linux cache hook and a 5 KiB
> freestanding PID 1. Its first 100-million-cycle acceptance control stopped
> exactly at that bound before any iDMA job, without a kernel failure
> signature; the preserved log is `out/control-tiny-init-100m.log`. A later
> DT-only attempt to reduce DMA-debug preallocation was ineffective because
> `CONFIG_CMDLINE_FORCE=y`; it is preserved as interrupted diagnostic evidence.
> The 200-million-cycle payload was rebuilt with
> `dma_debug_entries=1024` in the compiled command line. Its exact config,
> embedded string, software manifest, phase preflight and post-launch input
> audit pass. Its bounded attempts stopped before a DMA job. No Linux DMA pass
> is claimed because its exact UART, driver, cache, iDMA and AXI gates did not
> all pass.

## Result

The shortest practical Linux route is concrete and Linux executes in the
instrumented full-RTL model. The remainder of this report preserves the early
bounded-build investigation. No simulator is active and no Linux DMA
acceptance result is claimed.

The completed pieces are:

1. A RISC-V Linux 7.2.0 image with an embedded static initramfs,
   `CONFIG_DMA_API_DEBUG=y`, and `dmatest.ko`.
2. An investigation-only DMAengine provider that drives the real Cheshire
   iDMA register frontend and polls its completion ID because this wrapper has
   no completion interrupt.
3. A direct OpenSBI `fw_payload`: firmware at `0x80000000`, the Linux payload
   at `0x80200000`, and an embedded FDT.  This avoids U-Boot, SPI, SD, and a
   filesystem in the simulator.
4. A Verilator model containing the synthesizable locked CVA6 core, Cheshire
   interconnect, LLC, UART, and iDMA.  Only external DRAM is replaced with
   `axi_sim_mem`.
5. A pass gate requiring Linux dmatest to report eight successful copies,
   driver counters to read 8 submitted / 8 completed / 0 timed out, DMA API
   debug to report zero errors, and the RTL monitor to observe eight iDMA
   issue/retire events plus complete AXI read and write activity.

This is a build milestone, not a boot or DMA-pass result.  A 300-second run
ended at its wall-clock bound without preserved UART output.  Its stdout was
block-buffered and its fixed-name log was overwritten by the corrective run;
the resource record is preserved in
`out/verilator-linux-smoke-300s.RESULTS.txt`.  A 60-second line-buffered retry
printed only:

```
[TB] loading OpenSBI+Linux payload: .../out/fw_payload.memh
```

It then exited 124 at the wall-clock bound, with 602,508 KiB maximum RSS.  No
OpenSBI or Linux UART byte was seen.  The simulator model itself remained
alive.  The testbench currently prints no marker after `$readmemh`, so the
evidence does not establish whether payload parsing completed or reset was
released.

## Exact inputs

| Component | Revision/version |
|---|---|
| Cheshire | `292d2c091ffed3e194b0f437b5b3460813905e26` |
| locked CVA6 | `4c02b24fe7c04690f626776a92274da24f80d1da` |
| locked iDMA | `ff5d56fffb3767814db88d6bf8f381974ea33aa5` (v0.6.4) |
| Linux | `388b607d107c07aaade04c7f22f344cab6bdccd3` (7.2.0) |
| pulp-linux | `2df607d83b38721c2fd419357c6bf6d1db12df32` |
| OpenSBI submodule | `04c94d9c4014c570909036f893737e4af5e74744` |
| cva6-sdk | `df31dbe3c18f06027e07ba654ba7bbf861c63be3` |
| Bender | 0.32.1 |
| Verilator | 5.052 |
| RISC-V GCC | Ubuntu 15.2.0-16ubuntu1 |
| dtc | 1.7.2 |

The machine-readable record with local source paths is `out/REVISIONS.txt`.
No source repository was modified.  The Linux worktree was already dirty in
unrelated arm64 and virtio files; this work used a separate output directory.
The locked Cheshire worktree remained clean.  The successful Verilator build
processed 787 modules, took 86.245 seconds wall time, and used 615,472 KiB
maximum RSS.  It predates the four-job cap and records `--build-jobs 6`; the
reproduction script now defaults to four.

## Cache-maintenance blocker

The DT currently marks the experimental iDMA node `dma-coherent` only as a
deliberate hypothesis/negative control.  It is not a sound hardware contract.

The exact locked write-back CVA6 configuration has:

```
DcacheFlushOnFence      = 1
DcacheInvalidateOnFlush = 0
```

The HPDcache adapter consequently converts a flush request to
`HPDCACHE_REQ_CMO_FLUSH_ALL`, rather than
`HPDCACHE_REQ_CMO_FLUSH_INVAL_ALL`.  Linux RISC-V MMIO accessors place
`FENCE(w,o)` before writes and `FENCE(i,ir)` after reads.  That can write a
dirty DMA source back before launch, but it does not invalidate cached
destination lines after the device writes memory.  Dmatest initializes and
later reads destination buffers, so a stale DMA_FROM_DEVICE view is a real
risk even if the iDMA AXI transfer itself is correct.

Source locations at the pinned revisions:

- CVA6 configuration:
  `.bender/git/checkouts/cva6-20c9d7cbe0dd6995/core/include/cv64a6_imafdchsclic_sv39_wb_config_pkg.sv:50`
- HPDcache flush selection:
  `.bender/git/checkouts/cva6-20c9d7cbe0dd6995/core/cache_subsystem/cva6_hpdcache_if_adapter.sv:268`
- Linux MMIO ordering:
  `/home/karl/linux-work/linux/arch/riscv/include/asm/mmio.h:134`

The image does not enable `CONFIG_RISCV_DMA_NONCOHERENT` or Zicbom, and this
hardware description does not advertise Zicbom.  A useful Linux DMA pass
therefore needs one of these explicit choices:

1. Add proper CVA6 cache writeback and invalidation hooks and connect them to
   Linux's noncoherent DMA operations.  This is the production-oriented path.
2. Reserve and expose an uncached DMA pool/alias to the prototype driver.  This
   is narrower and useful for proving the RTL/software route.
3. Build a clearly labeled simulation variant with
   `DcacheInvalidateOnFlush=1`, then use the full-cache FENCE behavior as a
   coarse A/B experiment.  That variant differs from the locked physical RTL
   and does not establish a production ABI.

## Other source-proven limits

- Mainline Linux has no Cheshire/PULP iDMA DMAengine driver or DT binding.
  The driver and `pulp,cheshire-idma-v0` compatible here are test scaffolding,
  not an upstream proposal.  PULP iDMA issue 19 requested a Linux driver and
  was closed as not planned.
- The locked Cheshire wrapper instantiates iDMA with
  `ErrorCap(idma_pkg::NO_ERROR_HANDLING)` in `hw/cheshire_idma_wrap.sv:299`.
  This route cannot validate AXI error draining or reporting without an RTL
  variant that enables error handling.
- The wrapper exposes no completion IRQ or abort register.  The prototype
  serializes work in a workqueue, bounds DONE_ID polling at 65,536 reads, and
  cannot abort an active transaction.
- The current test covers DMA_MEMCPY, streaming map/unmap bookkeeping through
  dmatest, memory content/guard checks, and the physical AXI data path.  It does
  not cover IOMMU translation, dma-buf import/export, scatter-gather hardware,
  IRQ completion, peripherals, or injected AXI errors.

## What is simulated

The model runs synthesizable Cheshire/CVA6/LLC/iDMA/UART/interconnect RTL.  An
x86-64 Verilator executable advances it cycle by cycle.  A sparse software AXI
memory substitutes for external DRAM.  There is no physical FPGA fabric, DDR
controller/PHY timing, board clock/reset behavior, JTAG transport, or signal
integrity in this result.

Official Cheshire documentation supports real Linux FPGA builds for Digilent
Genesys 2, Xilinx VCU118, and Xilinx VCU128.  The official pulp-linux JTAG
sequence is:

```
openocd -f target/cheshire/cheshire.cfg
riscv64-unknown-linux-gnu-gdb
(gdb) target extended-remote localhost:3333
(gdb) load out/fw_payload.elf
(gdb) c
```

The custom DT and DMAengine module can follow that route only after the cache
contract is resolved.  Until then, physical FPGA execution could reproduce a
stale-cache failure but could not validate `dma-coherent`.

## Next bounded step

Do not launch another long run while the separate RTL campaign is consuming
the host.  First add a testbench message immediately after `$readmemh` and a
sparse periodic cycle counter, then rebuild at no more than four jobs.  This
separates payload-load time from CPU execution and gives a simulated-cycle
rate.  After the host is free, the existing commands are:

```sh
cd /home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-fpga-investigation
scripts/check-revisions.sh
BUILD_JOBS=4 scripts/build-software.sh
BUILD_JOBS=4 scripts/build-sim.sh
WALL_SECONDS=1800 MAX_CYCLES=50000000 scripts/run-smoke.sh
```

In parallel with that future boot check, implement one explicit cache strategy
above and run it as an A/B pair.  A PASS should be accepted only when the Linux
token, driver invariants, DMA API debug count, and independent RTL/AXI counters
all agree.

## Primary references

- Cheshire: <https://github.com/pulp-platform/cheshire>
- Official Cheshire simulation guide (documents bare-metal Questa/VCS flows):
  <https://github.com/pulp-platform/cheshire/blob/main/docs/tg/sim.md>
- Official Cheshire Xilinx/Linux guide:
  <https://github.com/pulp-platform/cheshire/blob/main/docs/tg/xilinx.md>
- Official pulp-linux tree and JTAG procedure:
  <https://github.com/pulp-platform/pulp-linux>
- PULP iDMA Linux-driver request:
  <https://github.com/pulp-platform/iDMA/issues/19>
