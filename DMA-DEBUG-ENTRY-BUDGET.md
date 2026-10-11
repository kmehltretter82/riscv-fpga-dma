# DMA API debug entry budget for RTL Linux boots

The pinned Linux tree enables `CONFIG_DMA_API_DEBUG`. Its default boot-time
table contains 65,536 entries (`1 << 16` in `kernel/dma/debug.c`).
`dma_debug_init()` allocates enough pages to hold the entire table before
`/init` runs. That is reasonable on hardware but dominates a cycle-accurate
CVA6 boot: the first bounded phase-7 and phase-8 runs spent 5,400 seconds in
that allocator, reaching 149 million and 144 million RTL cycles without
submitting a DMA job.

The replacement payloads use the kernel's existing
`dma_debug_entries=1024` boot option.  The baseline, AXI-error, and fuller
DMAengine kernels have `CONFIG_CMDLINE_FORCE=y`, so the option must be in
their compiled `CONFIG_CMDLINE`; a DT-only bootarg is ignored.  The mapping,
cache, and coherent kernels do not force `CONFIG_CMDLINE`, so their DT
bootargs are effective.  The option keeps DMA API debugging enabled and
changes only the number of simultaneously tracked mappings.  The kernel still
reports and counts map/unmap, direction, size, address, scatter-gather, and
coherent-allocation mistakes through the same code.

The bound has margin over each deterministic campaign:

| Campaign | Maximum relevant live mappings |
| --- | ---: |
| Linux AXI-error matrix | fewer than 16 |
| IRQ/queue/concurrency/abort matrix | fewer than 128 |
| Cache positive and stale-data controls | fewer than 16 |
| Direct/SWIOTLB mapping matrix | about 530 during the paired 265-entry SG case |

The mapping client also reads the DMA-debug error counter and fails on any
nonzero value. The 1,024-entry budget is therefore large enough for the most
demanding matrix while cutting 64,512 unused boot allocations. If future
tests increase the live-map peak, they must raise this option and retain an
explicit bound above the measured peak.

The first DT-only Linux AXI-error and fuller-DMAengine retries reached
`dma_debug_init()` at about 89 million RTL cycles and then continued sampling
page allocation.  Resolving those PCs against the exact `vmlinux` images
showed that the retries still behaved like the default-table boot.  Inspecting
their exact configurations then exposed `CONFIG_CMDLINE_FORCE=y`; the staged
DT option had never reached Linux.  Those runs were stopped and sealed rather
than represented as optimized evidence.  Corrected payloads require rebuilt
kernels whose compiled command line is checked verbatim by the build recipe.

The original bounded logs, input hashes, native status 124, and exact absence
of jobs or failure signatures are sealed under:

- `linux-error-investigation/out/failures/dma-debug-prealloc-65536-20261011/`
- `linux-driver-investigation/out/failures/dma-debug-prealloc-65536-20261011/`
- `regression/runs/20261011T132331Z-2-e7648289/` (Linux baseline,
  200,000,000 cycles)
- `regression/runs/20261011T132514Z-2-99567bb1/` (direct mapping,
  7,200-second wall bound at about 192,000,000 cycles)
- `regression/runs/20261011T133438Z-2-39c94171/` (legacy-WB cache,
  deliberately interrupted after 188,000,000 cycles)
- `regression/runs/20261011T133442Z-2-74433cd4/` (HPDcache,
  deliberately interrupted after 155,000,000 cycles)
- `regression/runs/20261011T133449Z-2-eefc2a27/` (forced SWIOTLB,
  deliberately interrupted after 159,000,000 cycles)

The five regression bundles record status `failed`, as they should: none of
those old payloads reached a DMA job.  The three manually stopped bundles also
record `interrupted=true`.  Their checksums and recorded failure semantics pass
`regression/verify.py --integrity-only`.

The mapping and cache helpers can prepare the change without rebuilding their
kernels because those configurations accept DT bootargs.  Each helper writes
a separate staging directory, compiles only the DTB and OpenSBI payload
wrapper, verifies the embedded boot arguments, and checksum-seals its outputs.
The baseline helper now also checks the compiled forced command line and
refuses to wrap an old kernel.  The AXI-error and fuller-DMAengine payloads are
rebuilt through their complete owning software recipes:

```sh
linux-fpga-investigation/scripts/prepare-fast-payload.sh
BUILD_JOBS=2 linux-error-investigation/scripts/build-software.sh
BUILD_JOBS=2 linux-driver-investigation/scripts/build-software.sh
linux-mapping-investigation/scripts/prepare-fast-payload.sh direct
linux-mapping-investigation/scripts/prepare-fast-payload.sh swiotlb
linux-cache-investigation/scripts/prepare-fast-payload.sh legacy
linux-cache-investigation/scripts/prepare-fast-payload.sh hpd
```

The mapping, HPDcache, and coherent payloads were promoted only after every
older run sharing their canonical inputs had stopped and been sealed. Their
software/input manifests were regenerated, and the binding passes dtschema
2026.9. Baseline, AXI-error, fuller-DMAengine, mapping, and cache attempts were
then run under fixed bounds. None reached a Linux DMA job, so their full gates
remain pending. The final negative DMA-API attempt reached 188 million cycles
at its 7,200-second limit; its sealed inputs still match. No simulator is
active.

Exact pre/post Image hashes, rebuilt config and payload hashes, verification
commands and run directories are recorded in
`FORCED-CMDLINE-REBUILD-20261011.md`.
