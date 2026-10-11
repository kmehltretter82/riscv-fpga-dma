# Validation record

Date: 2026-10-11 UTC

The following bounded checks completed on Hetzner:

| Check | Result |
|---|---|
| `scripts/check-source-contracts.sh` | PASS |
| Provider external-module compile against Phase 8 Linux output | PASS |
| Cache-test external-module compile against Phase 8 Linux output | PASS |
| Tiny init RV64 static compile with warnings as errors | PASS |
| Tiny init interpreter/undefined-symbol checks | PASS |
| Legacy DT template expansion and dtc compile | PASS |
| `scripts/check-coherent-static.sh` WT lint | PASS |
| Static non-WT bridge elaboration control | rejected as required |
| Shell syntax for every script | PASS |
| Complete kernel, modules, init, DT and two OpenSBI payloads | PASS |
| 13 software artifact checksums | PASS |
| Legacy-WB Verilator model build and two model/input hashes | PASS |
| HPDcache-WB Verilator model build and two model/input hashes | PASS |
| Legacy-WB and HPDcache-WB 100-cycle internal-bound controls | rejected as required |
| Original HPD write-response collision | reproduced at the exact assertion |
| Corrected HPD 30,000-cycle trigger-crossing control | reached bound; collision absent |
| Corrected HPD 250,000-cycle extended control | reached bound; collision absent |
| `scripts/check-hpd-id-reservation.sh` | PASS |

Static bridge logs and statuses are under `build/coherent-static/`.  Authored
inputs and pinned revisions are sealed in `out/SHA256SUMS.inputs`,
`out/INPUT-REVISIONS.txt`, and `out/SHA256SUMS.revisions`.

The collision diagnosis and its scope are in `HPDCACHE-ID-RESERVATION.md`.
No full Linux simulation completed. Runtime cells and all six legacy/HPD data
outcomes remain pending; no simulator is active.
