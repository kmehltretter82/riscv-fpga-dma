# Forced-command-line DMA-debug rebuild

Date: 2026-10-11 UTC

The baseline, Linux AXI-error, and fuller DMAengine kernels use
`CONFIG_CMDLINE_FORCE=y`.  Their first `dma_debug_entries=1024` retry changed
only `/chosen/bootargs`, so Linux ignored it and continued allocating the
default 65,536-entry DMA API debug table.  Those simulations were stopped and
sealed as interrupted diagnostic evidence.

The three owning config fragments and build recipes now require this exact
post-`olddefconfig` value:

```text
CONFIG_CMDLINE="console=ttyS0,1562500 quiet loglevel=4 rdinit=/init dma_debug_entries=1024"
CONFIG_CMDLINE_FORCE=y
```

Each full software recipe rebuilt the kernel, initramfs, modules, DTB and
OpenSBI payload.  For every workspace, the exact config lines matched,
`strings vmlinux` contained the complete command line, `/chosen/bootargs`
also contained the option, and `sha256sum -c out/SHA256SUMS.software` passed.

| Cell | `.config` SHA-256 | old Image SHA-256 | rebuilt Image SHA-256 | payload MEMH SHA-256 |
| --- | --- | --- | --- | --- |
| baseline | `287db8f7d9bf58dd32c7ddfc856cf5d95602e4213a1635b0b4028802cbce150f` | `3da969655d4ebb167eda5deb575d6bdb91622fb88ceb5e463ccdab6fa4bd2e55` | `ee548efede5118af21edcbfef5c0f8cb11fd265b2dfff12f916462593d495e85` | `756b8ecb4c37370b297cbda31c87b0a33b5aa975700f87e9098817e1c2dba027` |
| AXI errors | `40aaf027d2e5ffd44924c9b48210396a8c9aaf728f2198de87b42234a02afcad` | `e9d22ab69269a4894ecd9b570ae0d71d3c510b147a1f5cfa59a3165dd4f2452a` | `0ef45022d82df310c270253a96b94926ceb4318494621c3b2f4735acdbf5b1c8` | `8dd7062a7b9f0aab0965b48c6b1388eb5c0c896808f3296ce86bd53cd0060639` |
| fuller DMAengine | `e57eac2286b01d792afd9fc691ae40ff3837f0f0b5e8b7cc4fd742498444f759` | `ac4f4587ae386efdda0688de1c9e35d2f390ec94f181aa14b7800ccc19b48001` | `b674e71150caf551a2bbf9e6e4a3d2da82a0ab77f9d080ffbf78148af327f6f9` | `669ea4b9b1a780a1d404cd555ca9857101a60cfc5982fd56338bb00fa99c1908` |

The corrected regression runs are:

- baseline: `regression/runs/20261011T135524Z-2-fc7f5ae3/`
- AXI errors: `regression/runs/20261011T135524Z-2-cab484ad/`
- fuller DMAengine: `regression/runs/20261011T135524Z-2-2f40c90a/`

All three phase preflights and independent post-launch `audit-inputs.py`
checks passed.  A runtime pass is claimed only if each simulator later exits
through its exact manifest gates and the runner's post-execution input rehash.
