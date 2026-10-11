# RISC-V IOMMU reference-model result

Date: 2026-10-11

Source:
`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/sources/riscv-iommu-spec`
at `875e15459ef7ac99dfd313b2a8c0a19dba742e59`.

This is the behavioral C model shipped in the official ratified RISC-V IOMMU
specification repository.  It is an oracle/control tier; it does not establish
that the Zero-Day Labs RTL or Linux driver behaves the same way.

## Stock-harness findings

- The documented `make run` path returned status zero even when test 28 failed
  and the following `gcovr` command was unavailable.
- Direct execution reproduced the Sv32 failure in 4 of 100 fresh processes
  (runs 10, 27, 75 and 83).  Each failure stopped at
  `test/test_app.c:4107`.
- ASan found two 64-byte reads from the 16-byte `process_context_t PC` stack
  object at lines 2648 and 2658.
- UBSan found 32-bit shifts at exponents 36 and 31, plus stale loop-index shifts
  at exponents 576 and 288.
- After removing that undefined behavior, a diagnostic failing run returned
  status 1 with fault cause 262, “MSI PTE not valid,” for IOVA
  `0x19000000`.  The Sv32 setup used an all-ones MSI address mask, which
  classifies every address as MSI, and inherited device/process/IOTLB state
  from earlier tests.  A stale translation made the test pass; a real miss made
  it fail.

## Retained correction

`patches/iommu-ref-model-test-ub.patch`:

- uses the actual process-context size for both copies;
- uses 64-bit shifts and explicit page-table levels instead of stale indices;
- disables MSI translation in the Sv32-only setup; and
- invalidates cached device, process and address translations before the Sv32
  requests.

`scripts/run-reference-model.sh` invokes the binary directly and rejects a run
unless it exits zero, emits exactly 30 test records and 30 PASS markers, emits
no FAIL marker, and reaches test 30.  It checks the exact source revision and
that the retained patch is applied.  `SANITIZE=1` rebuilds every component
with ASan and UBSan.

## Accepted result

| Build | Fresh processes | Result |
| --- | ---: | --- |
| GCC 15.2.0 | 300 | 300/300, each 30/30 tests |
| GCC 15.2.0 + ASan + UBSan | 30 | 30/30, each 30/30 tests |

Evidence:

- `logs/ref-model-build.log`
- `logs/ref-model-run.log`
- `logs/ref-model-repeat.log`
- `logs/ref-model.sha256`
- `logs/ref-model-build-sanitized.log`
- `logs/ref-model-run-sanitized.log`
- `logs/ref-model-repeat-sanitized.log`
- `logs/ref-model-sanitized.sha256`

Patch SHA-256:
`5edc0bb38c88268bf2954053272ab30c6ab72e08ef3162d738e31aa60a8abb9a`.
