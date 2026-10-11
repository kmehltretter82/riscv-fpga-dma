#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
workspace=$(cd -- "$root/.." && pwd)
tools="$workspace/.tools"
sources="$root/build/sim-irq/sources.f"
build="$root/build/baremetal-irq-abort"

"$here/build-fw.sh"
[[ -s $sources ]] || {
  printf 'Missing phase source list; run scripts/build-sim.sh first\n' >&2
  exit 2
}
axi_dir=$(BENDER_DB_DIR="$workspace/.cache/bender-db" BENDER_LOCAL=true \
  "$tools/bin/bender" -d "$workspace/cheshire" path axi)

rm -rf -- "$build"
mkdir -p -- "$build"
/usr/bin/time -v "$tools/verilator-5.052/bin/verilator" \
  --binary --assert --timing --timescale 1ns/1ps \
  -Wno-fatal --error-limit 1000 \
  -f "$sources" "$here/axi_sim_mem_reset.sv" \
  "$here/tb_cheshire_dma_irq_abort.sv" \
  --top-module tb_cheshire_dma_irq_abort \
  --Mdir "$build/obj_dir" -o ../simv \
  --build-jobs "${BUILD_JOBS:-4}" > "$build/build.log" 2>&1
printf '0\n' > "$build/build.exit"

set +e
/usr/bin/time -v "$build/simv" \
  "+MEMH=$here/dma_irq_abort_test.memh" > "$build/run.log" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > "$build/run.exit"
cat "$build/run.log"
[[ $rc -eq 0 ]]
grep -q '^\[TB\] CVA6+iDMA IRQ-abort PASS$' "$build/run.log"
grep -q '^\[TB\] DMA activity: jobs=2/2 ' "$build/run.log"
grep -Eq '^\[TB\] IRQ/abort: irq_cycles=[2-9][0-9]* rises=2 acks=2 abort_accepts=1 post_terminal_writes=0 protocol_error=0 noop=0$' "$build/run.log"
