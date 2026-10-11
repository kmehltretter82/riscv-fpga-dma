# CVA6 + iDMA + RISC-V IOMMU simulation investigation

Status: supported architectural RTL suite accepted at 38/38; the complete
unsupported-feature diagnostic and fail-closed control are also retained.

This workspace turns Zero-Day Labs' open Genesys 2 integration into a bounded,
CPU-hosted RTL test.  No FPGA board or vendor simulator is required for the
acceptance run.

## Pinned sources

| Source | Revision |
| --- | --- |
| `sources/riscv-iommu` | `18ad30a7d2fd8fc0c0f16b99e39b0fd276437445` |
| `sources/riscv-iommu-tests` | `1ea9fcbb69153926694c4fe6e75b9f5f68b94440` |
| `sources/riscv-iommu-demo` | `2a0818a469f44b7a24781b02c4b07acc344a7634` |
| `sources/cva6-iommu` | `3009f0641dcf96e5003bc8f63babbdeec69b013b` |
| pinned FESVR/Spike source | `35d50bc40e59ea1d5566fbd3d9226023821b1bb6` |
| CVA6 integration's iDMA submodule | `f69e9f8eb6d9f3364921b9730921ebfc6a4ad819` |
| CVA6 integration's IOMMU submodule | `bdbe86df2817399a4663555d2454639bc82a22ad` |
| ratified-spec IOMMU reference model | `875e15459ef7ac99dfd313b2a8c0a19dba742e59` |

## Preparation findings

The pinned integration needed four simulator compatibility changes: tie off
Genesys-only push buttons, remove a stale iDMA IRQ port, enable Verilator 5
timing semantics, and provide an effective internal cycle limit.  Its PLIC
source boundary was also off by one: IOMMU WSI source 11 was driven both by
the IOMMU and the unused-source tie-off.  The retained integration patch fixes
that conflict so interrupt and fault-reporting results are meaningful.

The original architectural-test build could silently execute zero tests after
section garbage collection, report `passed 0 of 0` at `LOG_INFO`, return zero
after failed assertions, and then wait forever without notifying FESVR.  The
retained test patch keeps the registered test table, accounts assertions at
every verbosity, gives errors a nonzero status, and writes the encoded status
to HTIF `tohost`.  `scripts/build-arch-tests.sh` checks the ten-test table size,
symbol and actual `_exit` store instruction.

An initial detailed run retained all 12 upstream tests.  It produced 41
passing assertions and 13 failures: five in `mrif_support` and eight in
`dbg_interface`.  The locked RTL explicitly leaves MRIF unimplemented and
hardwires `capabilities.dbg` to zero.  Three of the 41 passes were also inside
the unsupported MRIF test.  The final accepted payload therefore excludes
those two complete tests and passes the remaining 38/38 assertions.

The official C reference model also needed its test harness made deterministic
before it could serve as an oracle.  Stock revision `875e154` failed the Sv32
case intermittently (4/100 processes) while its `runtests` shell wrapper still
returned success.  ASan found two 64-byte copies from a 16-byte process context;
UBSan found invalid and stale-index shifts.  The Sv32 case also reused cached
contexts and translations and enabled MSI matching for every address, so a
cache miss produced cause 262 instead of testing Sv32.  The retained patch fixes
the object sizes and shifts, disables unrelated MSI translation in that case,
and explicitly invalidates the device, process and translation caches.  The
fail-closed runner completed 300/300 normal processes and 30/30 ASan+UBSan
processes, with all 30 tests executed in each process.

## Reproduce

```sh
cd /home/karl/linux-work/dmadebug2/riscv-fpga-dma/iommu-investigation
scripts/build-fesvr.sh
scripts/build-arch-tests.sh
scripts/build-cva6-verilator.sh
scripts/run-bound-control.sh
scripts/run-arch-tests.sh
REPEAT=300 scripts/run-reference-model.sh
SANITIZE=1 REPEAT=30 scripts/run-reference-model.sh
```

The model build deliberately omits RVFI tracing and serializes Verilator's
front end to keep peak memory bounded.  The run wrapper requires the exact
38/38 assertion summary from all ten supported tests, native status zero,
FESVR completion, and no error or timeout marker.  The separate 100-cycle
control must return 124 with the internal-bound diagnostic and no completion
marker.

## Accepted RTL result

The supported suite completed after 710,175 simulated cycles in 9m01.55s with
native status zero and peak RSS 2,375,108 KiB.  It covers translated iDMA,
rejected transfers and fault records, IOTLB invalidation, I/O fences and
interrupt delivery.  The 100-cycle control exited 124 without a false
completion.  Full evidence and an independent semantic/checksum verifier are
at:

`/home/karl/linux-work/dmadebug2/hwtest/riscv-iommu-rtl-20261011/`

## Retained patches

- `patches/fesvr-modern-cstdint.patch`
- `patches/cva6-iommu-verilator-5-compat.patch`
- `patches/iommu-tests-modern-toolchain-and-exit.patch`
- `patches/iommu-ref-model-test-ub.patch`

This first tier exercises translated iDMA traffic, invalid mappings, IOTLB
invalidation, fault queues and interrupt generation through CVA6.  It is
CPU-hosted RTL simulation with a bare-metal payload; it contains no Linux and
uses no physical FPGA.  Linux IOMMU driver coverage and a differential run
against the behavioral model remain separate slower tiers.
