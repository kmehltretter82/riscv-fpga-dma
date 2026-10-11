# Cheshire Linux DMA investigation

This directory contains a separate, reproducible Linux-on-RTL path for the
locked Cheshire/CVA6/iDMA source tree.  It does not use or modify the
randomized bare-metal harness in `../cheshire-random-vlt`.

The software payload and Verilator model build successfully.  Linux has **not**
yet been observed booting in this model: a 300-second bounded run produced no
preserved UART output, and a line-buffered 60-second retry reached the firmware
memory-load message but emitted no OpenSBI byte before its wall-clock limit.
See `REPORT.md` for the evidence and the cache-coherency blocker discovered by
the source audit.

## What is here

- `dts/cheshire-linux-dma.dts`: 128 MiB, single-hart Cheshire DT plus an
  investigation-only iDMA node.
- `driver/cheshire-idma.c`: one-channel polling DMAengine provider for the
  real Cheshire iDMA register frontend.
- `init/init.c`: static initramfs controller which runs eight 4 KiB dmatest
  copies and checks DMA API debug and driver counters.
- `rtl/tb_cheshire_linux_dma.sv`: locked CVA6, Cheshire interconnect, LLC,
  iDMA, UART, and sparse simulated DRAM, with independent iDMA/AXI counters.
- `scripts/`: pinned-revision checks, software and simulator builds, and a
  bounded smoke run.
- `out/`: revision, checksum, and bounded-run evidence.  Large generated
  payloads are deliberately ignored by `.gitignore`.

## Reproduce

The scripts expect the already populated local source and tool trees named in
`out/REVISIONS.txt`.  They reject a different Cheshire, Linux, pulp-linux, or
OpenSBI commit.  Builds default to four jobs.

```sh
cd /home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-fpga-investigation
scripts/check-revisions.sh
BUILD_JOBS=4 scripts/build-software.sh
BUILD_JOBS=4 scripts/build-sim.sh
WALL_SECONDS=1800 MAX_CYCLES=50000000 scripts/run-smoke.sh
```

Do not spend another long simulation run until the testbench prints a marker
after `$readmemh` and periodic cycle progress.  The current evidence cannot
distinguish slow payload parsing from slow execution after reset.

## Physical FPGA route

Upstream Cheshire documents Linux on Digilent Genesys 2, Xilinx VCU118, and
Xilinx VCU128 boards.  The official `pulp-linux` route programs a Cheshire
bitstream, starts OpenOCD with `target/cheshire/cheshire.cfg`, and loads
`fw_payload.elf` from GDB.  This investigation's direct OpenSBI payload is the
shortest equivalent software path, but it must not be used for a meaningful
DMA result until the CVA6 noncoherent cache-maintenance contract described in
`REPORT.md` is fixed.

