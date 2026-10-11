# Phase 8 design: interrupt-driven Cheshire DMAengine provider

Snapshot: 2026-10-11

## Scope and acceptance boundary

This phase turns the polling investigation provider into an interrupt-driven,
single-hardware-channel DMAengine provider.  It adds a phase-only RTL ABI for
completion acknowledgement and active abort, routes completion and DMA bus
errors to usable PLIC inputs, and tests software queueing and cancellation.

The driver remains investigation code.  It is not an upstream proposal until
the RTL register and interrupt ABI is reviewed by Cheshire/iDMA maintainers.
The current hardware has no byte-progress register, so the only truthful
residue contract is `DMA_RESIDUE_GRANULARITY_DESCRIPTOR`: the full descriptor
length while queued or active, zero after successful completion, and the full
length for an aborted descriptor.  This phase must not claim byte or burst
residue.

Phase 8 starts only after the phase-6 Linux baseline and phase-7 Linux-visible
AXI-error run pass their sealed gates.

## Why RTL changes are required

The locked Cheshire wrapper exposes `NEXT_ID` and `DONE_ID` only as polling
registers.  It has no completion output, interrupt acknowledgement, or
software abort register.  Its iDMA backend accepts the `ABORT` error-handler
action only after an AXI error has moved the handler out of `IDLE`; asserting
the existing request in `IDLE` does nothing.  A Linux driver alone therefore
cannot provide interrupt completion or active cancellation.

The existing DMA UNBENT recorder has level interrupts, but its packed source
IDs are 54 and 55 while the generated PLIC has 32 inputs.  Those lines are
truncated before the PLIC.  Phase 8 explicitly routes two DMA signals into low
internal IDs rather than pretending that a DT change can expose IDs 54/55.

## Phase-only RTL ABI

### PLIC sources

Add two fields directly above `uart` in the tail of
`cheshire_int_intr_t`, retaining `zero` as bit 0 and `uart` as bit 1:

| PLIC source | Signal | Trigger contract |
|---:|---|---|
| 2 | `dma_completion` | level, asserted while `DONE_ID != IRQ_ACK_ID` |
| 3 | `dma_error` | level, OR of DMA BusErr read/write FIFO nonempty IRQs |

This shifts currently higher internal source numbers by two in the phase
variant.  The Linux payload enables only UART and DMA, and the phase DT names
the exact IDs.  Preserve the original source ordering outside the detached
phase worktree.

### Completion interrupt and acknowledgement

Add `completion_irq_o` to `cheshire_idma_wrap`.  On the first cycle out of
reset, initialize a 32-bit `irq_ack_id` from the frontend's reset `done_id`,
then drive:

```
completion_irq_o = irq_initialized && (done_id != irq_ack_id)
```

A successful read transaction of stream-0 `DONE_ID` at offset `0x84`
captures the returned `done_id` into `irq_ack_id`.  The read remains a normal
frontend register read; it gains acknowledgement side effects only in this
phase ABI.  A driver may read `DONE_ID` before launching the first job to
discard reset/stale state.  The IRQ handler reads it once to acknowledge all
completed IDs visible at that instant.

The testbench must assert that every `done_id` advance raises the level until
a `DONE_ID` read, every acknowledgement clears it when no newer completion
exists, and no completion edge is lost across a delayed PLIC claim.

### Software abort register

The enabled 2D frontend uses every offset through `0xfc` and decodes eight
address bits.  Intercept full aperture offset `0x100` between `axi_to_reg_v2`
and the frontend before it can alias register `0x00`:

| Access | Bits | Meaning |
|---|---:|---|
| write | 0 | enqueue one abort request for the active stream |
| read | 0 | abort request pending |
| read | 1 | backend/error-handler busy |
| read | 2 | a transfer is active (`NEXT_ID != DONE_ID + 1`, modulo 32 bits) |
| read | 31:3 | zero |

Call this register `ABORT_STATUS`.  A write with bit 0 clear is a no-op.
Reject partial writes that do not cover byte lane zero.  The request remains
pending until the backend accepts it; a second write while pending sets a
sticky protocol-error counter visible to the RTL testbench and does not queue
another action.

Extend the focused iDMA error-handler patch so an `ABORT` request is accepted
in `IDLE` only when exactly one transfer is outstanding.  Capture that
transfer's `last` flag, enter the existing `LEG_FLUSH` path, drain accepted AXI
traffic, kill the legalizer, and emit exactly one terminal response.  If zero
transfers are outstanding, acknowledge the command as a no-op and count it.
The phase driver never exposes more than one descriptor to hardware, so the
ambiguous `num_outst > 1` case is an RTL assertion and test failure.

An aborted terminal response still advances `DONE_ID`; software owns the
aborted classification because the existing response carries no abort bit.
The driver must retain an `abort_requested` flag for the active descriptor and
complete it as `DMA_TRANS_ABORTED`, with full descriptor residue.

## Linux driver state machine

Use `virt-dma` for the software queue and expose one DMAengine channel.  Keep
exactly one descriptor active in hardware.

1. `device_issue_pending()` moves submitted descriptors to the issued list.
2. Under the channel lock, `start_next()` removes the head descriptor, records
   its full length and cookie, programs source/destination/length, launches it,
   and records the returned `NEXT_ID`.
3. The error IRQ drains both BusErr banks in the mandatory
   address/high/meta/code order and records one error classification against
   the active descriptor.  It never completes the descriptor because the
   backend may still be draining accepted traffic.
4. The completion IRQ reads `DONE_ID`, acknowledges the level, verifies that
   the active issued ID is covered, drains any BusErr record that raced the
   error IRQ, assigns `NOERROR`, `READ_FAILED`, `WRITE_FAILED`, or `ABORTED`,
   completes exactly one cookie, and launches the next software descriptor.
5. If `DONE_ID` covers more than the one active ID, fail the investigation
   counter gate; the driver intentionally never has two hardware-active jobs.

Both IRQ handlers serialize state with the same channel spinlock.  BusErr MMIO
reads happen outside that lock only if the active descriptor is pinned by a
separate state lock; the simpler phase implementation may use one raw spinlock
for both because all reads are non-sleeping MMIO.

`device_tx_status()` returns:

- queued descriptor: full length residue;
- active descriptor: full length residue;
- completed-success descriptor: zero residue;
- terminal error/abort callback: full length residue.

`device_terminate_all()` must be callable from atomic context.  Under the
channel lock it detaches queued descriptors without invoking their callbacks.
If a descriptor is active, it marks `abort_requested`, writes bit 0 to
`ABORT_STATUS`, and returns without sleeping.  Its eventual terminal IRQ moves
the descriptor to the terminated list, signals an internal stop completion,
and deliberately does not call the client callback.  This follows the
DMAengine provider contract that incomplete terminated transfers receive no
completion callback.

`device_synchronize()` performs the sleeping half: wait with a fixed bound for
an active abort's terminal response, call `synchronize_irq()` for both lines,
then use `vchan_synchronize()` to drain tasklet/callback state and free the
terminated descriptors.  The timeout quarantines the channel and increments a
hard failure counter; it does not free memory still reachable by hardware.

Do not call a descriptor terminated until the abort's terminal response has
advanced `DONE_ID`.  A timeout is a test failure and leaves the channel
quarantined; it must not launch the next queued descriptor.

## Device-tree binding draft

Create and validate an investigation-only schema named
`Documentation/devicetree/bindings/dma/pulp,cheshire-idma.yaml` with:

```
compatible = "pulp,cheshire-idma-v0.6.4-test"
reg-names = "control", "bus-error"
interrupts = <2>, <3>
interrupt-names = "completion", "error"
#dma-cells = <1>        /* only channel specifier 0 is valid */
dma-channels = <1>
```

The node remains noncoherent and must not carry `dma-coherent`.  Document that
this temporary compatible includes the read-to-ack `DONE_ID` behavior and the
  `ABORT_STATUS` register at offset `0x100`.  Run `dt_binding_check` if the
pinned kernel tree has its schema dependencies; always run `dtbs_check` or a
direct schema validation against the phase DT.

## Runtime matrix

One Linux boot may execute the following serial groups.  Each group has fresh
guarded buffers and an exact counter gate.

1. **IRQ controls:** eight clean copies of 8, 64, 257, 4096, and
   page-crossing sizes; require one terminal callback and one acknowledged
   completion level per descriptor, no polling fallback, and clean guards.
2. **Queue depth:** submit 16 descriptors before `issue_pending`; require FIFO
   callback order, cookies complete once, maximum software queue depth at
   least 15, and maximum hardware-active depth exactly one.
3. **Concurrent submitters:** two kernel threads submit 16 descriptors each
   to the same channel with distinct patterns; require all 32 callbacks,
   preserved data/guards, and no lockdep, list, or cookie diagnostics.
4. **Read/write errors:** repeat one SLVERR and one DECERR in each direction,
   each followed by a clean recovery; require error IRQ observation plus the
   terminal completion IRQ and the same BusErr classification as phase 7.
5. **Queued terminate:** queue eight jobs behind a phase-stalled first job,
   call `terminate_sync`, require seven jobs never reach hardware, no callback
   for any incomplete descriptor, and all eight descriptors freed only after
   the hardware-active job has stopped.
6. **Active abort:** hold a long transfer with bounded AXI response delay,
   issue terminate while the transfer is observably active, release responses,
   and require an accepted abort, complete drain, one terminal response, no
   client callback for the terminated descriptor, the recorded conservative
   full-length residue, no destination writes after the terminal response,
   and a clean recovery copy.

The bounded-delay target must eventually return every response already
accepted before abort.  A slave that never responds cannot prove drain or
bounded cancellation and is not a valid abort test.

## Exact evidence gate

The final bundle must retain and independently verify:

- zero polling completions and one or more completion IRQs;
- balanced descriptor submitted/terminal callback/free counts;
- exact issue/retire ID deltas and one hardware-active maximum;
- no duplicate callbacks or cookies and ordered queue-group callbacks;
- both concurrent producers' payload and guard checks;
- exact four AXI error classes and four BusErr IRQ observations;
- queued cancellation and one active hardware abort with terminal drain;
- descriptor-level residue values matching the contract above;
- a successful clean recovery after errors and after active abort;
- zero DMA API debug, lockdep, IRQ, PLIC, protocol, timeout, panic, or warning
  signatures introduced by the run;
- RTL assertions covering level/ack behavior, BusErr drain, abort handshake,
  outstanding AXI balance, and no post-terminal writes;
- pinned source revisions, all phase patches, build commands, raw log, native
  exit status, and a complete SHA-256 manifest.

## Deliberately deferred to phase 9

Scatter-gather preparation, coherent allocations, non-page-aligned streaming
mappings, SWIOTLB/bounce operation, and the large boundary matrix belong to
the mapping phase.  Phase 8 uses memcpy descriptors to validate the interrupt,
queue, error, cancellation, and residue contracts without mixing in a second
set of variables.
