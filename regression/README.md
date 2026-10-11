# Cheshire RISC-V DMA regression harness

This directory packages the CPU-hosted Cheshire DMA tests behind one
fail-closed runner.  It does not need an FPGA board.  It treats the existing
phase workspaces as inputs and writes every new result under `regression/runs/`.
The runner executes prebuilt models directly, so it does not overwrite the
fixed-name logs in those workspaces.

The default `baremetal-ci` tier is deliberately small:

1. one deterministic 16-descriptor randomized CVA6+iDMA cell with the tested
   channel-coupler credit backport;
2. the focused completion-IRQ and active-abort/drain proof; and
3. all 30 tests in a dedicated normal (non-sanitized) build of the patched
   IOMMU C reference model.  Normal and sanitizer executables are retained
   under distinct names so the last reference-model build cannot silently
   change this regression input.

The `linux` tier boots three separate payloads: the eight-copy DMAengine
baseline, the Linux-visible SLVERR/DECERR matrix, and the fuller IRQ/queue/
concurrency/residue/terminate driver matrix.  It runs them sequentially.  Each
model has a 200-million-cycle internal bound and a 7,200-second external wall
bound.  The `iommu-rtl` tier has a 100-cycle expected-timeout control followed
by the supported 38-assertion CVA6/IOMMU suite. The `mapping` tier runs the
direct-DMA and forced-SWIOTLB Linux payloads sequentially, with 250-million-
cycle and 7,200-second bounds for each boot. The `cache` tier runs a fast
fail-closed control followed by each 200-million-cycle legacy-WB and
HPDcache-WB Linux cell, then the bounded control and full CVA6-WT coherent
cell. Each full cell contains one positive copy and two deliberately stale
negative controls.

## Inspect and run

All commands below are safe to run from any working directory.

```sh
REG=/home/karl/linux-work/dmadebug2/riscv-fpga-dma/regression

# Show tiers, phases, planned work, and live prerequisite failures.
"$REG/run.py" --list

# Validate the default tier, expand its exact commands, and run nothing.
"$REG/run.py" --dry-run

# Run the bounded CI tier.
"$REG/run.py"

# Exercise runner IDs, evidence sealing, semantic replay, tamper rejection,
# and the before/after input-integrity check without starting RTL.
"$REG/selftest.py"

# Recheck live prerequisites and tracked source after a completed run.  This
# reads the sealed bundle and writes nothing unless --output names a path
# outside it.
"$REG/audit-inputs.py" "$REG/runs/RUN_ID"

# Run one or more explicit phases.
"$REG/run.py" --phase baremetal-irq-abort
"$REG/run.py" --phase linux-baseline --phase linux-axi-errors

# Run the slower tiers.
"$REG/run.py" --tier linux
"$REG/run.py" --tier iommu-rtl
```

`--tier` and `--phase` are repeatable and their union runs in declaration
order with duplicates removed.  The default is fail-fast.  `--keep-going`
retains later independent results after a failed gate.  An explicit
`--timeout-seconds N` replaces every selected phase's wall bound, but the
runner accepts only `1..86400` seconds.  Processes receive `SIGTERM` as a
group at the bound, then `SIGKILL` after ten seconds.

Preflight checks every selected command, simulator, payload, and revision
root before creating a result directory or starting a phase.  A phase marked
`ready` means its invocation and acceptance contract are defined; it can
still report a missing prebuilt model.  For example, the focused error-drain
phase remains unavailable after its model was cleaned until
`cheshire-error-vlt/build-autoabort-drain/simv` is rebuilt.  Planned phases
cannot run and explain what is missing.

Immediately before and after each phase, the runner rehashes its prerequisites
and recaptures its Git state.  If another job rebuilds a model, replaces a
payload, or changes tracked source during or before a slow phase, the run fails
instead of being attributed to stale preflight metadata.

`audit-inputs.py` provides the same comparison later without changing the run
directory.  It is useful for old or adopted runs and for an independent
post-run audit; an optional `--output` file must be outside the sealed bundle.

## Exact acceptance contracts

[`manifest.json`](manifest.json) contains argv arrays rather than shell text,
per-phase timeouts, required inputs, Git revision roots, allowed native exit
codes, required regexes with exact match counts, and forbidden markers.  The
important contracts are:

| Phase | Exact accepted result |
| --- | --- |
| `baremetal-random` | 16/16 jobs, fixed seed `0x12345678`, descriptor hash `0x94544f21`, zero AXI errors |
| `baremetal-irq-abort` | 2/2 jobs, two IRQ rises/acks, one accepted abort, no post-terminal write |
| `iommu-reference` | exactly 30 `PASS` test lines and the named test 30 |
| `baremetal-error-drain` | exactly 12 read/write, stall, and burst-position cases |
| `linux-baseline` | one Linux pass token, 8/8 jobs, nonzero AXI activity, balanced cache operations |
| `linux-axi-errors` | 9/9 jobs, four classified errors, four recorder pushes/pops, IDs 9/9 |
| `linux-dmaengine` | 67/67 hardware jobs, exact IRQ/error/abort/cache/ID accounting |
| `iommu-bound-control` | native status 124, one 100-cycle timeout marker, no completion marker |
| `iommu-architecture` | exactly `Summary: passed 38 of 38`, FESVR completion, no failure marker |
| `linux-mapping-direct` | 272 direct jobs, 540 physical-alias proofs, 814 client cache operations, zero DMA API errors |
| `linux-mapping-swiotlb` | 271 jobs, 538 bounce-address proofs, 269 source-copy checks, 811 client cache operations, zero DMA API errors |
| `cache-legacy-bound`, `cache-hpd-bound` | native status 1 at exactly 100 cycles and no cache pass token |
| `cache-legacy-negative` | positive copy plus exact stale-source and stale-destination outcomes, 3/3 jobs, 96 read/write beats |
| `cache-hpdcache` | the same three outcomes plus only `FLUSH_INVAL_ALL` HPD CMOs |
| `cache-coherent-bound` | native status 1 at exactly 100 cycles and no coherent-cache pass token |
| `cache-coherent` | 3/3 jobs through CVA6-WT's real drain/invalidation path; one held WT source line and one omitted destination-line invalidation must expose the exact stale outcomes |

The RTL testbenches enforce additional invariants before printing their pass
tokens.  The manifest repeats the externally important counters so a stale or
wrong executable cannot pass on a generic success line alone.

## Evidence format

Every real invocation creates one unique directory such as:

```text
runs/20261011T120000Z-12345-a1b2c3d4/
  runner.py
  verify.py
  audit-inputs.py
  manifest.snapshot.json
  host.json
  preflight.json
  run.json
  SHA256SUMS
  PHASE/
    invocation.json
    process.log
    result.json
    native/                 # adapter-owned detailed logs, when applicable
```

The final random component keeps concurrent invocations distinct even inside
PID namespaces where independent runners can both appear as PID 2.

Completed long runs started by the phase wrappers can be sealed without
rerunning them. `adopt.py` copies a stable log and native exit file, evaluates
the same manifest gates, captures current prerequisite hashes and source
diffs, and labels the result as adopted so it cannot be confused with a run
launched by `run.py`:

```sh
"$REG/adopt.py" --phase linux-baseline \
  --log /absolute/path/to/verilator.log \
  --exit-file /absolute/path/to/verilator.exit \
  --source-command 'WALL_SECONDS=7200 MAX_CYCLES=200000000 scripts/run-smoke-no-trace.sh'
```

Adoption requires a completed, stable source log. Its preflight describes the
state at adoption; the original phase input manifests remain the start-time
integrity record for wrapper-launched runs.
Use `--interrupted` when a source wrapper was deliberately stopped; the native
status and failed gate are then preserved without mislabeling it as a normal
completion.

`preflight.json` records hashes, sizes, and mtimes for every declared binary
and payload.  It also records each Git HEAD, tracked dirty state, and a hash of
the complete tracked diff.  `result.json` records native status, wall time,
timeout state, and every individual regex-gate count.  Failed and interrupted
runs are sealed too. The exact runner and verifier are copied into each bundle
and their hashes are also recorded in `run.json`. `SHA256SUMS` covers every
regular evidence file other than itself. The raw process log retains terminal color sequences; regex
gates evaluate an ANSI-stripped view so harmless upstream coloring cannot
change the result.

Verify a successful bundle with:

```sh
"$REG/verify.py" "$REG/runs/RUN_ID"
```

For forensic evidence from an expected failed run, verify integrity while
allowing its recorded failure state:

```sh
"$REG/verify.py" --integrity-only "$REG/runs/RUN_ID"
```

The verifier rejects malformed, absolute, duplicate, missing, extra, and
checksum-mismatched paths.  It also checks the sealed manifest hash, replays
every exact required and forbidden regex against each sealed process log, and
requires the recomputed phase and overall statuses to match `result.json` and
`run.json`.

## Rebuild boundary and current limits

The regression runner intentionally does not build Verilator models, kernels,
OpenSBI, or firmware.  Those builds have different memory and time budgets;
mixing them into a CI smoke would make its bound misleading.  Rebuild with
the owning phase scripts, inspect their build exit/log files, then rerun
`--list` and `--dry-run`.  Input hashes make a rebuilt model visibly distinct
in every result bundle.

The architectural IOMMU gate accepts the 38 assertions in the ten complete
tests implemented by the locked RTL.  A payload that still registers the
unsupported MRIF and debug
interface tests will fail this gate rather than silently reducing coverage.
The CVA6/IOMMU executable opens its integration's unused localhost JTAG
socket, so a restricted container must permit that local socket.

The direct-mapping, forced-SWIOTLB, legacy-WB, HPDcache-WB and CVA6-WT
coherent full cells remain unaccepted; their bounded attempts stopped before
the Linux clients ran. Their fail-closed controls pass. The final deliberate
DMA-API-misuse attempt reached 188 million cycles before its 7,200-second wall
limit, with no panic, RTL assertion, or iDMA issue, but also without reaching
PID 1. It is retained as integrity-verified diagnostic evidence. No simulator
is active. This harness validates simulated synthesizable RTL and software; it
does not cover FPGA timing closure, DDR PHY/controller behavior, board
reset/clocking, or physical signal integrity.
