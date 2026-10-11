# Phase 7 design: Linux-visible Cheshire AXI error handling

Snapshot: 2026-10-11T07:57:58Z

## Decision

The smallest useful phase-7 campaign is one CPU-hosted Verilator boot with
Linux submitting nine serialized, aligned 8-byte DMAengine memcpy descriptors:

1. clean control;
2. source read returning `SLVERR`;
3. clean recovery;
4. destination write returning `SLVERR`;
5. clean recovery;
6. source read returning `DECERR`;
7. clean recovery;
8. destination write returning `DECERR`;
9. clean recovery.

Use the already-verified error-capable iDMA drain patches, enable Cheshire's
existing UNBENT bus-error recorder, and add one mapped AXI error aperture to a
phase-only copy of the Linux testbench. Leave a second address unmapped so the
normal crossbar decode-error slave returns `DECERR`. No new error register or
Linux-visible interrupt is required for this polling campaign.

This is a design audit. Nothing in this directory is a boot result, and this
audit did not build or simulate anything. The current Linux baseline has
printed Linux kernel output in Verilator, but it has not yet reached `/init` or
completed a DMAengine test. Phase 7 should run only after that baseline reaches
its existing pass token.

## Locked inputs and reusable fixes

The exact revisions and working-tree state are in `REVISIONS.txt`. The source
snapshot is in `SOURCE-HASHES.txt`.

The functional error variant must reuse these three files:

- `/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire-error-vlt/autoabort-drain.patch`
  changes the Cheshire wrapper from `NO_ERROR_HANDLING` to `ERROR_HANDLING`,
  filters an intermediate error notification from transfer retirement, sends
  one `ABORT` action through a sequenced request/response handshake, and waits
  for the terminal backend response. See patch lines 21-25, 57-103, 112-126.
- `/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire-error-vlt/idma-error-drain.patch`
  preserves the errored transfer's `last` bit and includes the write-last FIFO
  in `dp_busy`, so the abort drain does not finish while response metadata is
  still pending. See patch lines 5-49 and 56-142.
- `/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire-error-vlt/verilator-error-handler-compat.patch`
  is a Verilator assertion-syntax compatibility patch. It is not a functional
  error-handling change.

Apply them only in detached phase worktrees. The proven overlay order is the
one in
`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire-error-vlt/run.sh:57-92`:
apply `autoabort-drain.patch` to Cheshire; apply
`verilator-error-handler-compat.patch` and then `idma-error-drain.patch` to a
locked iDMA worktree; generate the source list and substitute those two
worktree paths. Do not modify
`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire` or
`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-fpga-investigation`.

The predecessor campaign is sealed at
`/home/karl/linux-work/dmadebug2/hwtest/riscv-cheshire-cva6-dma-errors-20261011/REPORT.md`.
Its 12 read/write, burst-position, and stall cells established exactly one
backend error notification, a terminal abort response, balanced issue/retire,
and a successful recovery job with this patch set. That result was bare-metal;
phase 7 adds Linux/DMAengine observation rather than repeating its randomized
harness.

## Existing BusErr hardware and exact register ABI

Cheshire already monitors the DMA master's request and response at the system
crossbar boundary. The instance has a four-entry recorder per direction,
`DropOldest=0`, and enough request-address tracking for the configured DMA
in-flight and job FIFO depths:

- `/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_soc.sv:1514-1535`
- `/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_soc.sv:1480-1509`

`RegBusErrDma` is index 1
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_pkg.sv:286-289`).
Every BusErr instance occupies `0x40` bytes starting at `0x03009000`
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_addrmap_pkg.sv:56-57`),
and the generated map adds `index * 0x40`
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_pkg.sv:425-427`).
The DMA recorder block is therefore exactly `0x03009040-0x0300907f`.

Address bit 5 selects the read bank; zero selects the write bank
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/unbent-a93c32aef5b319fd/src/axi_err_unit_wrap.sv:56-68`).
Each bank has the offsets generated at
`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/unbent-a93c32aef5b319fd/src/bus_err_unit_reg_pkg.sv:50-54`:

| Direction | Register | Absolute address | Meaning |
|---|---|---:|---|
| write | `ERR_ADDR` | `0x03009040` | failing AW address bits 31:0 |
| write | `ERR_ADDR_TOP` | `0x03009044` | address bits 47:32 in bits 15:0; upper bits zero |
| write | `ERR_CODE` | `0x03009048` | response/full fields below; reading pops one entry |
| write | `META` | `0x0300904c` | AXI ID in bits 1:0; upper bits zero |
| read | `ERR_ADDR` | `0x03009060` | failing AR address bits 31:0 |
| read | `ERR_ADDR_TOP` | `0x03009064` | address bits 47:32 in bits 15:0; upper bits zero |
| read | `ERR_CODE` | `0x03009068` | response/full fields below; reading pops one entry |
| read | `META` | `0x0300906c` | AXI ID in bits 1:0; upper bits zero |

The relevant `ERR_CODE` fields are:

| Bits | Meaning |
|---:|---|
| 1:0 | raw AXI response: `2` = `SLVERR`, `3` = `DECERR` |
| 30:2 | zero in this configuration because `AxiUserErrBits=0` |
| 31 | recorder FIFO is full when `ERR_CODE` is sampled |

AXI defines `SLVERR=2'b10` and `DECERR=2'b11` at
`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_pkg.sv:91-100`.
UNBENT copies only responses whose bit 1 is set
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/unbent-a93c32aef5b319fd/src/axi_err_unit_wrap.sv:39-53`).
The address and metadata widths come from Cheshire's 48-bit address and 2-bit
DMA-master ID configuration at
`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_pkg.sv:551-560`.

Read `ERR_ADDR`, then `ERR_ADDR_TOP`, then `META`, and read `ERR_CODE` last.
`ERR_CODE` read enable is the FIFO pop signal
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/unbent-a93c32aef5b319fd/src/bus_err_unit.sv:95-105`).
Reading it first can advance the FIFO and make the later address/meta reads
describe the next entry.

Bit 31 is named `err_fifo_overflow` in the wrapper, but the implementation
wires it directly to the current `full` signal
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/unbent-a93c32aef5b319fd/src/bus_err_unit_bare.sv:118-150`).
It is neither a sticky history bit nor a dropped-entry count. With
`DropOldest=0`, an error arriving while full is not pushed. The phase must call
this counter `fifo_full_seen`, fail if it is nonzero, and independently require
exactly four RTL pushes and four Linux-triggered pops.

The recorder has no software-readable empty/count register. Its FIFO memory is
reset to zero, but after its read pointer wraps an empty FIFO can expose stale
memory. This nine-job plan records only two errors per directional four-entry
FIFO and reads both banks after every DONE, so it never wraps. That makes a
zero code usable in this bounded campaign. A reusable production driver would
need a readable empty/count bit or a working interrupt/status path before it
could poll indefinitely without this bound.

## Why the BusErr IRQ cannot be used in this locked SoC

UNBENT exposes separate level interrupts: write is `err_irq_o[0]`, read is
`err_irq_o[1]`
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/unbent-a93c32aef5b319fd/src/axi_err_unit_wrap.sv:81-93,111-123`).
They remain asserted while their FIFO is nonempty
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/unbent-a93c32aef5b319fd/src/bus_err_unit_bare.sv:51-55`).

They do not reach the locked PLIC. The packed internal interrupt structure puts
`zero` at bit 0 and `uart` at bit 1, matching the current UART DT interrupt 1.
Counting the fixed fields in
`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_pkg.sv:213-249`
places DMA BusErr write at bit 54 and read at bit 55. The locked OpenTitan PLIC
has only 32 sources
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/opentitan_peripherals-7b624fb57f78de9a/src/rv_plic/rtl/rv_plic_reg_pkg.sv:7-13`),
and Cheshire explicitly connects only `[NumSrc-1:0]`
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_soc.sv:1127-1138`).
Bits 54 and 55 are truncated.

Consequences for the minimal phase:

- Keep the PLIC node and `riscv,ndev = <20>` unchanged.
- Add no `interrupts` property to the iDMA node.
- Poll `DONE_ID`, then read both BusErr banks. The recorder's internal IRQs are
  still useful as RTL pass/fail signals even though Linux cannot receive them.

An IRQ-driven follow-up is not a DT-only change. It must regenerate or replace
the PLIC with at least 56 sources, or explicitly reroute the two DMA BusErr
lines into reachable source positions. Only then should DT raise `riscv,ndev`
and describe the validated write/read source IDs. A 58-source PLIC would retain
the packed write/read IDs 54/55 and cover all current internal fields; this has
not been built or tested.

## Safe SLVERR and DECERR apertures

Use these phase-only DMA bus addresses:

| Address range | Response | Construction |
|---|---|---|
| `0x40000000-0x40000fff` | `SLVERR` | one mapped external AXI slave using `axi_err_slv` |
| `0x50000000-0x50000fff` | `DECERR` | deliberately leave this range unmapped |

The current Linux RAM is only `0x80000000-0x83ffffff`
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-fpga-investigation/dts/cheshire-linux-dma.dts:14-18`).
Both fault apertures are also below Cheshire's LLC output region, which starts
at `0x80000000`
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_pkg.sv:600-602`).
They cannot alias or corrupt the kernel, initramfs, DT, or ordinary DMA test
buffers. Do not describe either aperture as system memory and never access it
with CPU loads or stores.

The testbench's phase copy should change `gen_linux_cfg()` as follows:

```systemverilog
ret.BusErr            = 1;
ret.AxiExtNumSlv      = 1;
ret.AxiExtNumRules    = 1;
ret.AxiExtRegionIdx   = '0;
ret.AxiExtRegionStart = '0;
ret.AxiExtRegionEnd   = '0;
ret.AxiExtRegionIdx[0]   = 0;
ret.AxiExtRegionStart[0] = 64'h4000_0000;
ret.AxiExtRegionEnd[0]   = 64'h4000_1000;
```

Connect `axi_ext_slv_req_o/rsp_i` instead of tying them off at
`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-fpga-investigation/rtl/tb_cheshire_linux_dma.sv:96-120`,
and instantiate:

```systemverilog
axi_slv_req_t [0:0] fault_req;
axi_slv_rsp_t [0:0] fault_rsp;

axi_err_slv #(
  .AxiIdWidth ($bits(axi_slv_id_t)),
  .axi_req_t  (axi_slv_req_t),
  .axi_resp_t (axi_slv_rsp_t),
  .Resp       (axi_pkg::RESP_SLVERR),
  .ATOPs      (1'b1),
  .MaxTrans   (1)
) i_slverr (
  .clk_i      (clk),
  .rst_ni     (rst_n),
  .test_i     (1'b0),
  .slv_req_i  (fault_req[0]),
  .slv_resp_o (fault_rsp[0])
);
```

The error slave generates `Resp` on both B and every R beat
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_err_slv.sv:19-27,141-150,183-210`).
The system crossbar has its default port disabled
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_soc.sv:251-280`),
so an address with no rule selects its internal `RESP_DECERR` slave
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/axi-ecdc900686449c15/src/axi_xbar_unmuxed.sv:95-134,195-211`).
Do not add a rule for `0x50000000`.

Do not inject errors in the external DRAM model. The LLC can satisfy or defer
those transactions and CPU traffic shares that path. Do not override only the
wrapper-local response either: the BusErr recorder observes the outer
`axi_in_req/rsp` signals at `cheshire_soc.sv:1531-1532`. The two apertures above
produce real interconnect responses seen by both iDMA and BusErr while limiting
the fault to explicitly targeted descriptors.

Use aligned 8-byte transfers. On this 64-bit bus that is one R beat and one B
response, so each intended fault generates one record. A longer read from an
always-error slave can create an error record for every R beat and overflow the
four-entry recorder before Linux can drain it.

## DT and Linux changes

Make all changes in a phase copy of the baseline files.

Extend the existing iDMA node with the BusErr MMIO resource:

```dts
idma: dma-controller@1000000 {
        compatible = "pulp,cheshire-idma-v0";
        reg = <0x0 0x01000000 0x0 0x1000>,
              <0x0 0x03009040 0x0 0x0040>;
        reg-names = "control", "bus-error";
        #dma-cells = <1>;
        status = "okay";
};
```

Add an investigation-only platform client with two resources and the existing
DMA channel:

```dts
dma-error-test@40000000 {
        compatible = "openai,cheshire-idma-error-test";
        reg = <0x0 0x40000000 0x0 0x1000>,
              <0x0 0x50000000 0x0 0x1000>;
        reg-names = "slverr", "decerr";
        dmas = <&idma 0>;
        dma-names = "memcpy";
        status = "okay";
};
```

These `reg` properties reserve bus resources for the test client; they do not
add AXI routing rules. The client must obtain the physical starts but must not
`ioremap()` or CPU-dereference them. Map each fault endpoint with
`dma_map_resource(dmaengine_get_dma_device(chan), address, 8, direction, 0)`
and check `dma_mapping_error()`. Use `DMA_TO_DEVICE` when the aperture is the
source and `DMA_FROM_DEVICE` when it is the destination. Unmap it with the same
device, size, and direction. The pinned kernel implements this as an MMIO DMA
mapping and explicitly performs no cache maintenance
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-fpga-investigation/sources/linux-cheshire-cache/include/linux/dma-mapping.h:62-80` and
`kernel/dma/mapping.c:363-375`).

The provider's phase copy of
`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-fpga-investigation/driver/cheshire-idma.c`
should:

1. map resource 0 by `reg-names = "control"` and resource 1 by
   `reg-names = "bus-error"`;
2. retain its single worker and one-active-descriptor rule
   (`cheshire-idma.c:150-178`);
3. after `DONE_ID` reaches the issued ID, snapshot address-low, address-high,
   and meta, then read/pop code for the write bank; repeat for the read bank;
4. return `DMA_TRANS_NOERROR` when both codes are zero,
   `DMA_TRANS_READ_FAILED` for exactly one read-bank code,
   `DMA_TRANS_WRITE_FAILED` for exactly one write-bank code, and
   `DMA_TRANS_ABORTED` for both banks, bit 31, an unknown code, or an invalid
   recorded address;
5. leave `tx_result.residue` at zero. The provider already advertises
   `DMA_RESIDUE_GRANULARITY_DESCRIPTOR`, which means residue is unsupported and
   must remain zero (`include/linux/dmaengine.h:462-485`);
6. call `vchan_cookie_complete()` as today. Virt-dma passes `vd->tx_result` to
   `callback_result` (`drivers/dma/virt-dma.c:83-108`).

For a timeout, read both recorder banks for diagnostics, set
`DMA_TRANS_ABORTED`, and increment `timeouts`; do not call the transfer
recovered. The frontend has no software abort register, as documented at
`cheshire-idma.c:202-216`.

Expose read-only counters at least for:

```text
submitted completed timeouts success
read_failed write_failed aborted
slverr decerr buserr_records fifo_full_seen unexpected
```

For this phase-only address check, give the provider read-only
`expected_slverr_addr=0x40000000` and
`expected_decerr_addr=0x50000000` module parameters when `/init` loads it.
Match raw code 2 to the first address and code 3 to the second; a mismatch
increments `unexpected` and returns `DMA_TRANS_ABORTED`. This is test
instrumentation, not a proposed provider ABI.

The test client must use `tx->callback_result`, not the legacy `tx->callback`.
The result enum can report source-read versus destination-write failure
(`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/linux-fpga-investigation/sources/linux-cheshire-cache/include/linux/dmaengine.h:545-558`),
but it cannot distinguish `SLVERR` from `DECERR`; retain that distinction only
in provider logs/counters. `dma_cookie_status()` will say the cookie is
complete after `vchan_cookie_complete()`, including an error completion, so it
is not evidence of the error type.

Mainline dmatest is unsuitable for the error cells. It installs only the
legacy callback at `drivers/dma/dmatest.c:824-829`, then accepts a complete
cookie at `drivers/dma/dmatest.c:840-867`. It never consumes
`callback_result`. A failed destination B response can also occur after all
data was accepted, allowing its data comparison to pass. Retain dmatest for
the baseline; use the dedicated client for this error matrix.

Map ordinary scratch buffers with the normal DMA API and unmap them before CPU
verification. Allocate source and destination separately with cache-line
alignment, map each full guarded allocation, and transfer only the aligned
8-byte payload. Give every recovery job freshly initialized buffers and
require an exact payload copy plus untouched guards. A read fault may write
error-slave poison into its owned destination scratch buffer; that is allowed
and must not be reused as a recovery source.

## Ordering and race analysis

There is no DONE-versus-recorder race with the fixed, serialized design:

1. The UNBENT recorder sees the external R/B response handshake and pushes an
   error record from that handshake
   (`axi_err_unit_wrap.sv:39-49,86-93,116-123` and
   `bus_err_unit_bare.sv:118-143`).
2. The error-capable backend turns that response into an intermediate iDMA
   response with `error=1`; the locked handler source shows read/write error
   creation at
   `/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/.bender/git/checkouts/idma-77bf7fa56d324e6a/src/backend/idma_error_handler.sv:232-274`.
3. `autoabort-drain.patch` accepts that notification, does not retire it,
   handshakes `ABORT`, waits through the drain, and forwards the later terminal
   non-error response (patch lines 21-25 and 57-103).
4. Only that terminal response asserts `retire_id`; the transfer-ID generator
   then advances `DONE_ID`
   (`/home/karl/linux-work/dmadebug2/riscv-fpga-dma/cheshire/hw/cheshire_idma_wrap.sv:189-202`,
   as modified by the patch).

Thus a CPU observation of the incremented `DONE_ID` occurs after the BusErr
entry exists. The driver should use ordered `readl()` calls after DONE. The RTL
monitor should independently assert that the appropriate recorder IRQ went
high before the failed descriptor's DONE transition and stayed high until the
CPU read `ERR_CODE`.

Recorder overflow cannot race this plan because the client waits for every
callback, the provider launches only one descriptor at a time, each fault has
one error response, and the provider pops both banks before launching the next
descriptor. Require `fifo_full_seen=0` and monitor the internal full signals
anyway. Do not generalize this guarantee to queued hardware descriptors or
multi-beat always-error reads.

UNBENT metadata is the AXI ID, not a DMAengine cookie. Exact cookie attribution
is valid only because this provider has one active descriptor. Supporting more
than one active descriptor would need stronger hardware metadata or a
driver-enforced serialization contract.

## One-boot pass gate

Linux must report all of the following:

| Counter/result | Required value |
|---|---:|
| submitted | 9 |
| completed terminal responses | 9 |
| success / `DMA_TRANS_NOERROR` | 5 |
| `DMA_TRANS_READ_FAILED` | 2 |
| `DMA_TRANS_WRITE_FAILED` | 2 |
| `DMA_TRANS_ABORTED` | 0 |
| raw `SLVERR` | 2 |
| raw `DECERR` | 2 |
| BusErr records | 4 |
| timeouts | 0 |
| FIFO-full observations | 0 |
| unexpected records/codes/addresses | 0 |
| callback-result mismatches | 0 |
| clean/recovery data and guard checks | 5 passed |
| DMA API debug error count | 0 |

If the client maps and unmaps fresh normal RAM for every job, the pinned
noncoherent cache hook should increase by exactly 21: three operations for
each of five clean copies, two for each of two read-fault destinations, and
one for each of two write-fault sources. MMIO resource mappings do no cache
maintenance. Record a before/after delta rather than an absolute boot count.
Also require every RTL cache-flush request to receive an acknowledgement.

The RTL monitor must independently require:

| Oracle | Required value |
|---|---:|
| iDMA issue / retire | 9 / 9 |
| backend response handshakes | 13 |
| backend error notifications | 4 |
| error-handler ABORT action handshakes | 4 |
| read `SLVERR` / write `SLVERR` responses | 1 / 1 |
| read `DECERR` / write `DECERR` responses | 1 / 1 |
| UNBENT pushes / code-read pops | 4 / 4 |
| recorder FIFO-full cycles | 0 |
| read/write recorder IRQ at end | 0 / 0 |
| `NEXT_ID` / `DONE_ID` delta | +9 / +9 |
| final iDMA busy | 0 |
| cache flush requests / acknowledgements | equal, nonzero |

The Linux pass token is accepted only after both the Linux table and RTL table
match. Preserve the complete UART log, simulator stdout/stderr, exit status,
payload hashes, source hashes, kernel config, DTB decompile, and per-job
addresses/results.

## Implementation recommendation

First obtain the existing baseline's `/init` and dmatest pass without any
phase-7 change. Then make detached Cheshire/iDMA worktrees plus a copied Linux
campaign directory, apply the three proven patches, enable BusErr and the one
SLVERR aperture, and replace dmatest with the nine-job callback-result client.
Run one boot and accept it only with both counter tables above. The remaining
uncertainty is integration rather than the bare-metal drain mechanism: the
Linux baseline has not reached its test controller, the bounded empty-FIFO
polling scheme has not run, and the locked PLIC cannot carry the recorder
interrupts.

## Claims this phase can and cannot support

If it passes, the phase can show that the CPU-hosted synthesizable
Cheshire/CVA6/interconnect/iDMA RTL, with the named functional patches,
propagates mapped `SLVERR` and unmapped `DECERR`, drains and retires the failed
descriptor, lets Linux correlate the existing bus-error recorder with its one
active DMAengine descriptor, delivers read/write failure through
`callback_result`, and completes a clean job after every error. External DRAM
remains a software AXI memory model, and the SLVERR target is a testbench AXI
slave.

It cannot establish any of these without additional work:

- exact bytes transferred or residue after an abort: the frontend exposes no
  progress address/count, and descriptor granularity explicitly means no
  residue support;
- hardware completion IRQ semantics: this wrapper exposes no completion IRQ;
- BusErr IRQ delivery on this locked SoC: sources 54/55 are outside its
  32-source PLIC;
- indefinite FIFO polling: there is no readable empty/count bit and empty data
  can become stale after pointer wrap;
- cookie attribution with multiple descriptors in hardware: recorder metadata
  carries only AXI ID;
- a software-requested abort: the wrapper exposes no abort register;
- `SLVERR` versus `DECERR` through the generic DMAengine result enum;
- physical FPGA behavior: the testbench fault aperture is not present in a
  board bitstream unless the board wrapper deliberately instantiates/routes an
  equivalent target, and the functional patches must be synthesized;
- an upstream binding or production driver ABI: all compatible strings and
  driver code here remain investigation scaffolding.

These limits are pass criteria boundaries, not optional caveats. Do not report
phase 7 as a Linux DMA error pass until the baseline reaches `/init` and the
full one-boot gate above completes.
