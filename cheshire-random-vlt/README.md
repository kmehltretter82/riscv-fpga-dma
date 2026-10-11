# Cheshire CVA6/iDMA randomized RTL campaign

This harness boots bare-metal RV64 firmware on CVA6 inside the complete
Cheshire SoC RTL and drives Cheshire's integrated iDMA through its real MMIO
register interface. It does not boot Linux and does not model an IOMMU or
hardware cache coherence.

The 2026-10-11 campaign reproduced the two known channel-coupler defects in
Cheshire's locked iDMA v0.6.4: stale AW release from an empty queue and AW
starvation when `decouple_rw=1` gives the read and write sides unequal burst
counts. A backport of the later upstream write-data credit logic passed 27/27
cells and 3,456/3,456 jobs. The checksum-sealed report and raw evidence are in:

`/home/karl/linux-work/dmadebug2/hwtest/riscv-cheshire-cva6-dma-random-20261011/`

For every seed, `cases.py` independently reproduces the firmware's descriptor
stream and FNV-1a hash. The full-geometry mix covers 1D and 2D copies,
unaligned lanes, lengths around bus/burst/page boundaries, page crossings, row
gaps, and all four Cheshire iDMA decoupling settings. Firmware checks payload
bytes, destination guards and gaps, and source immutability.

The multi-seed duration campaign uses the same generator and checks with a
separate recorded profile flag. It caps lengths at 257 bytes, rows at four and
row gaps at 31 bytes so CVA6's uncached verification loops do not dominate the
RTL run. Near-page placement still creates page crossings. Full-geometry smoke
retains lengths through 4,097 bytes and up to eight rows.

The testbench provides three memory timing modes:

- direct AXI
- fixed AXI input/output delays
- deterministic pseudo-random delay of 0 through 7 cycles on each of AW, W, B,
  AR, and R

It can reset the full SoC while iDMA is busy and can insert one-shot read or
write `SLVERR` responses. Production Cheshire instantiates iDMA with
`NO_ERROR_HANDLING`, so the error cells require the response to be observed and
the copy to continue. Error-capable iDMA behavior and its completion fix are
tested separately in `../cheshire-error-vlt/`.

Run the six-cell smoke test:

```sh
./run.sh smoke
```

Run the default 27-cell, 128-descriptor campaign:

```sh
CAMPAIGN_JOBS=6 ./run.sh campaign
```

That command uses the stock locked source and is expected to hit the known
v0.6.4 failures. `idma-channel-coupler-credit.patch` is the tested Cheshire
backport. `metadata/COMMANDS.txt` in the evidence bundle records how the final
patched model and matrix were produced. The patch changes Cheshire's compiled
generated RTL but not v0.6.4's generator templates, so it is an integration
backport rather than an upstream-ready patch.

Run one reproducible cell:

```sh
RESULT_DIR=/tmp/cheshire-random \
  ./run.sh cell example 0x12345678 64 random reset
```

Prove that the firmware oracle detects an intentionally corrupted final write:

```sh
./run.sh data-fault
```

The locked source revisions are selected by `../cheshire/Bender.lock`. The
runner uses the retained Bender cache at `../.cache/bender-db`, builds firmware
with `riscv64-linux-gnu-gcc`, and uses Verilator 5.052 from `../.tools/`.
