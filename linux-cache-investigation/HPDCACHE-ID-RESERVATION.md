# HPDcache write-response ID collision

Date: 2026-10-11 UTC

## Finding

The first HPDcache Linux attempt did not fail because of reset, source-list
substitution, AXI memory timing, or a spontaneous response.  It exposed an ID
namespace collision in the locked CVA6 HPDcache integration at commit
`4c02b24fe7c04690f626776a92274da24f80d1da` (`pulp-v2.0.0`).

The integration copies `CVA6Cfg.WtDcacheWbufDepth` into both
`wbufDirEntries` and `flushEntries`.  The selected target supplies a 4-bit
memory ID and a depth of eight.  HPDcache encodes write responses as follows:

| Owner | IDs with a 4-bit memory ID |
|---|---|
| Write buffer | `0000` through `0111` |
| Flush directory | `1000` through `1111` |
| Uncached handler | `1111` |

Flush entry 7 and the uncached handler therefore both own `1111`.  The write
response demultiplexer tests the all-ones uncached ID before the flush range,
so a legitimate response for flush entry 7 is delivered to the idle uncached
handler.

## Runtime evidence

The original full attempt failed at simulator time `221450000` in
`hpdcache_uncached.sv:988`.  A diagnostic rebuild sampled the assertion inputs
at the same point:

```text
[HPD-DIAG] uc_write=1 uc_read=0 uc_state=0 flush_dir_valid=0xff
```

This establishes all four parts of the collision: it was a write response, the
response was decoded as uncached, the uncached FSM was idle, and all eight
flush entries were occupied.  The original and diagnostic logs are preserved
under `out/failures/hpd-uc-unexpected-response-20261011/` with checksums.

## Local correction

The Phase 11 HPD target now sets `CVA6ConfigWtDcacheWbufDepth` to seven.  This
leaves the all-ones ID exclusively owned by the uncached handler.  It is the
smallest correction available through the locked CVA6 configuration package;
it reduces the write-buffer and flush-directory capacity by one entry.  A
future upstream-quality change should expose separate flush-depth and
write-buffer-depth parameters and assert that the configured ranges fit the
ID namespace.

The independently applicable target patch remains at
`patches/cva6-hpdcache-wb-fence-invalidate.patch` and now contains the ID
reservation together with the WB/FENCE/flush-invalidate selection.

## Bounded validation

The corrected simulator was rebuilt from the pinned sources.  Its normal
100-cycle fail-closed control still rejects an incomplete run.  Separate
30,000-cycle and 250,000-cycle controls both crossed the original trigger,
performed the first `FLUSH_INVAL_ALL`, and reached only their intentional
internal timeout.  Neither log contains the uncached-response assertion.

Run the evidence gate with:

```sh
cd /home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-cache-investigation
scripts/check-hpd-id-reservation.sh
```

The bounded full Linux HPDcache attempt was stopped before a DMA job. These
short controls therefore validate only the specific early-boot correction;
the exact three-oracle Linux pass gate remains pending.
