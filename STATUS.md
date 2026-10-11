# RISC-V DMA-debug lab status

Date: 2026-10-11 UTC

This workspace is stopped at a reproducible source-and-evidence checkpoint. No
RTL simulator is active.

## Accepted results

- The CI-sized Cheshire/CVA6/iDMA tier passes deterministic randomized DMA,
  completion IRQ, active abort/drain, and all 30 IOMMU reference-model tests.
- The focused error tier passes all 12 read/write SLVERR cases, including
  delayed responses and clean recovery, with the iDMA error-drain correction.
- The architectural CVA6+iDMA RISC-V-IOMMU suite passes its 38 supported
  assertions. Unsupported MRIF and debug-interface cases remain explicit.
- Legacy-WB, corrected HPDcache-WB, and CVA6-WT coherent fail-closed controls
  pass. Focused bridge and ID-reservation checks pass.
- The regression runner provides fixed cycle/wall limits, exact-count and
  forbidden-signature gates, source/input hashing, checksum-sealed bundles,
  semantic replay, and tamper self-tests.

## Linux runtime boundary

The Linux kernels, DMAengine providers, test clients, DT bindings, OpenSBI
payloads, and Verilator models build and pass their static/preflight checks.
Full baseline, AXI-error, DMAengine, direct, SWIOTLB, and cache cells did not
reach their Linux DMA jobs inside the campaign bounds, so no full Linux DMA
result is claimed.

The final deliberate DMA-API-misuse run is sealed as
`regression/runs/20261011T184621Z-2-4ca094ea/`. Its 100-cycle fail-closed phase
passed. The full phase reached 188 million cycles of ordinary Linux
initialization and then hit its 7,200-second wall limit. It recorded zero iDMA
issues and no panic, RTL assertion, or test-failure signature, but it did not
reach PID 1, so the five intentional API errors did not execute. The bundle
passes 13 checksum/semantic integrity checks, and both post-run input audits
match.

## Reproduction and archive

`SOURCES.tsv` in the source-only archive locks 19 public repositories and
revisions. The 12 patches under `upstream-patches/` reverse-check against the
live patched trees. `bootstrap-sources.sh` reconstructs those trees without
overwriting existing paths. Generated kernels, simulators, tool installations,
and multi-gigabyte traces are omitted.

The accepted compact regression bundles and the final failed diagnostic bundle
are retained under `evidence/`. Run `verify-release.sh` from the archive root
to validate them. The host metadata contains a generic host name and software
versions, with no IP address or credentials.

## Remaining work

- Complete one Linux boot through PID 1, then run the negative DMA-API cell.
- Run the direct and forced-SWIOTLB mapping matrices.
- Run Linux-visible AXI error/recovery and the full DMAengine queue/abort cell.
- Complete the legacy-WB, HPDcache-WB, and CVA6-WT positive/stale-data matrix.
- Run the same payload on supported physical FPGA hardware when available.
