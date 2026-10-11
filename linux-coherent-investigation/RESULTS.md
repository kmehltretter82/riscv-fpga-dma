# Phase 11 coherent cell build result

Status: build and bound control accepted; no full Linux runtime claim.

The configuration is single-core Cheshire with the CVA6 WT cache.  A private
bridge drains and quiesces the real WT subsystem before normal DMA traffic,
records destination write lines, sends those lines through CVA6's upstream WT
invalidation port, and withholds the downstream AXI B response until the last
invalidation is accepted.  Elaboration fails outside this one-core WT scope.

The deterministic stale-source negative holds one aligned 16-byte line in the
real CVA6 WT buffer.  Software establishes OLD_SRC in RAM, pre-arms the line's
physical address, writes NEW_SRC into that line, and starts a 16-byte DMA.  The
fault skips only the pre-DMA drain.  The testbench releases the held write after
the last DMA read beat, and the normal post-transfer quiesce drains it.  Runtime
acceptance requires the pre-arm, release, and at least one actual held-write
cycle.  The stale-destination negative drops only line index 8 and requires
that one line old with the other fifteen lines new.

Completed checks:

- focused bridge/model regression: three cases passed;
- full Cheshire/CVA6 Verilator elaboration and executable build: exit 0;
- Linux kernel, provider, client, DTB, OpenSBI payload, and memh build: passed;
- provider/client module dependency and exported pre-arm symbol: resolved;
- 100-cycle full-system fail-closed control: native exit 1, zero jobs, no pass;
- integration patches apply to the three locked source revisions;
- source contracts, compiled DT properties, YAML binding semantics, and a
  warning-free DTB-to-DTS round trip: passed;
- independent `dt-doc-validate` with dtschema 2026.9 and Ubuntu's extracted
  `python3-libfdt`, through a temporary `dma/` path matching `$id`: passed;
- all recorded SHA-256 manifests: passed.

Primary evidence:

- `build/sim-coherent/build.log`
- `build/sim-coherent/SHA256SUMS.sim`
- `out/bridge-regression.log`
- `out/coherent-bound-100.log`
- `out/SHA256SUMS.software`
- `out/SHA256SUMS.dt-contract`
- `out/fw_payload-coherent.memh`

Long simulations were started after the build checks, but were stopped before
PID 1 issued a DMA job. The positive and two stale-data outcomes therefore
remain pending, and no simulator is active.
