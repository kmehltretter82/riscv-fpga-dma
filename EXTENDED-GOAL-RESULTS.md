# Extended RISC-V FPGA/RTL DMA goal

Date: 2026-10-11 UTC

Acceptance uses CPU-hosted execution of synthesizable RTL.  No physical FPGA
result is required or claimed because no supported Cheshire board is
available.

| Goal item | Acceptance evidence | Status |
| --- | --- | --- |
| Linux-visible AXI errors | Error-capable Cheshire/iDMA; read/write SLVERR and DECERR; exact drain, single completion and clean recovery gates through DMAengine | 12-cell bare-metal drain matrix accepted; Linux client pending |
| Fuller DMAengine provider | Completion/error IRQs, software queue, two concurrent submitters, descriptor residue, active abort, queued terminate and recovery; temporary DT binding | Focused IRQ/abort RTL control accepted; Linux client pending |
| Mapping coverage | Direct and forced-SWIOTLB streaming maps, 265-entry SG, byte/page/boundary crossings and coherent allocations under DMA API debug | Built and gated; full Linux clients pending |
| RISC-V IOMMU | CVA6+iDMA+IOMMU translated/rejected DMA, first/second-stage invalidation, fault records, fences and interrupts; independent ratified-spec model | Accepted |
| Cache comparison | Legacy CVA6 WB, corrected HPDcache WB and CVA6 WT coherent paths; positive copy plus exact stale-source/stale-destination controls | Bound controls accepted; full Linux cells pending |
| Repeatable regression | CI and slow tiers, exact gates, internal/wall bounds, input and Git-state hashing before and after execution, collision-safe run IDs, checksummed evidence, semantic replay and tamper tests | Harness accepted; slow Linux results pending |

## Accepted controls

- `hwtest/riscv-cheshire-cva6-dma-error-regression-20261011/` verifies 72
  outer checksums, 33 retained-run checksums, 728 semantic checks and all
  12 read/write error-drain cells.
- `hwtest/riscv-cheshire-cva6-dma-irq-abort-20261011/` verifies completion IRQ,
  active abort, terminal drain, no post-terminal write and clean recovery.
- `hwtest/riscv-iommu-rtl-20261011/` verifies the supported CVA6+iDMA+IOMMU
  suite at 38/38 assertions, including the 100-cycle fail-closed control.
- `hwtest/riscv-iommu-reference-model-20261011/` verifies all 30 tests in 300
  normal and 30 ASan/UBSan processes.
- `regression/runs/20261011T111155Z-2/` is the accepted CI-sized bare-metal
  tier; `regression/verify.py` replays and verifies all 17 checksums.
- `regression/runs/20261011T114005Z-2/` is the accepted error-drain tier;
  `regression/verify.py` replays and verifies all 33 checksums.
- `regression/runs/20261011T113800Z-2/` contains the accepted legacy and
  HPDcache fail-closed controls.
- `regression/runs/20261011T125255Z-2-11015ca6/` contains the accepted coherent
  fail-closed control.
- `regression/selftest.py` passes 128 concurrent run-ID checks, accepted-bundle
  and standalone input-auditor checks, semantic and manifest tamper rejection,
  and mutation-during-run rejection.
- `regression/READY-ALL-DRY-RUN-20261011.txt` records a successful 17-phase
  preflight after the three forced-command-line payloads were rebuilt (SHA-256
  `137e45c5fed4ca45f0ee273354daf4d24aed21aa90e19311316ba409b030e315`).

## Linux runtime disposition

| Phase | Representative run directory | Final state |
| --- | --- | --- |
| baseline control | `regression/runs/20261011T135524Z-2-fc7f5ae3/` | stopped before any DMA job; no acceptance claim |
| AXI errors | `regression/runs/20261011T135524Z-2-cab484ad/` | stopped before any DMA job; no Linux error/recovery claim |
| fuller DMAengine | `regression/runs/20261011T135524Z-2-2f40c90a/` | stopped before any DMA job; no Linux queue/abort claim |
| direct mapping | `regression/runs/20261011T133925Z-2-abe4eb9c/` | wall bound before any DMA job |
| forced SWIOTLB | `regression/runs/20261011T133934Z-2-aef5fada/` | stopped before any DMA job |
| HPDcache WB | `regression/runs/20261011T133938Z-2-2b428c17/` | bound control passed; full cell stopped before a job |
| CVA6 WT coherent | `regression/runs/20261011T132431Z-2-f77873db/` | bound control passed; full cell stopped before a job |
| DMA-API negative | `regression/runs/20261011T184621Z-2-4ca094ea/` | bound control passed; full run reached 188 million cycles but not PID 1 |

All corrected payloads passed preflight and source/input audits. The final
negative bundle passes 13 integrity checks and both phase input audits. It has
zero iDMA issue records and no panic, assertion, or test-failure signature,
but the deliberate API mistakes never ran. No simulator remains active.
