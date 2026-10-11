#!/usr/bin/env bash
set -euo pipefail

mode=${1:-baseline}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd -- "$script_dir/.." && pwd)
cheshire_dir="$workspace/cheshire"
idma_repo="$workspace/idma"
tools_dir="$workspace/.tools"
idma_commit=ff5d56fffb3767814db88d6bf8f381974ea33aa5
fault_tree="$script_dir/.idma-fault-fullsoc"
fault_worktree=0

case "$mode" in
  baseline|data-fault) ;;
  *) echo "usage: $0 {baseline|data-fault}" >&2; exit 2 ;;
esac

cleanup() {
  if [[ $fault_worktree == 1 && ${KEEP_WORKTREE:-0} != 1 ]]; then
    git -C "$idma_repo" worktree remove --force "$fault_tree" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

export BENDER_DB_DIR="$idma_repo/.bender/git/db"
export BENDER_LOCAL=true

if [[ ! -d "$cheshire_dir/.bender/git/checkouts" ||
      ! -d "$idma_repo/.bender/git/db" ]] ||
   ! "$tools_dir/bin/bender" -d "$cheshire_dir" path axi >/dev/null 2>&1; then
  cat >&2 <<EOF
Locked Cheshire dependencies are absent.  Restore them with:
  cd $workspace
  BENDER_DB_DIR=$idma_repo/.bender/git/db \\
    $tools_dir/bin/bender -d $cheshire_dir checkout --no-progress
Then rerun this command.  The retained Cheshire Bender.lock selects the exact revisions.
EOF
  exit 2
fi

"$script_dir/fw/build.sh"

sources="$script_dir/sources.f"
"$tools_dir/bin/bender" -d "$cheshire_dir" script verilator \
  -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb > "$sources"

if [[ $mode == data-fault ]]; then
  if [[ -e $fault_tree ]]; then
    git -C "$idma_repo" worktree remove --force "$fault_tree"
  fi
  git -C "$idma_repo" worktree add --detach "$fault_tree" "$idma_commit"
  fault_worktree=1
  git -C "$fault_tree" apply "$script_dir/fault-corrupt-final-write.patch"
  idma_dep=$("$tools_dir/bin/bender" -d "$cheshire_dir" path idma)
  sed "s|$idma_dep|$fault_tree|g" "$sources" > "$script_dir/sources-fault.f"
  sources="$script_dir/sources-fault.f"
fi

build_dir="$script_dir/build-cva6-dma"
if [[ $mode == data-fault ]]; then
  build_dir="$script_dir/build-cva6-dma-fault"
fi
rm -rf -- "$build_dir"
mkdir -p -- "$build_dir"

/usr/bin/time -v "$tools_dir/verilator-5.052/bin/verilator" \
  --binary --assert --timing --timescale 1ns/1ps \
  -Wno-fatal --error-limit 1000 \
  -f "$sources" "$script_dir/axi_sim_mem_reset.sv" \
  "$script_dir/tb_cheshire_cva6_dma.sv" \
  --top-module tb_cheshire_cva6_dma \
  --Mdir "$build_dir/obj_dir" -o ../simv \
  --build-jobs "${BUILD_JOBS:-6}" \
  > "$build_dir/build.log" 2>&1
printf '0\n' > "$build_dir/build.exit"

run_sim() {
  local stem=$1
  shift
  set +e
  /usr/bin/time -v "$build_dir/simv" \
    "+MEMH=$script_dir/fw/dma_cpu_test.memh" "$@" \
    > "$build_dir/$stem.log" 2>&1
  sim_rc=$?
  set -e
  printf '%s\n' "$sim_rc" > "$build_dir/$stem.exit"
  cat "$build_dir/$stem.log"
}

check_clean_run() {
  local stem=$1
  [[ $sim_rc -eq 0 ]]
  grep -q '\[TB\] CVA6+iDMA firmware PASS:' "$build_dir/$stem.log"
  grep -q 'DMA activity: jobs=30/30 busy_cycles=' "$build_dir/$stem.log"
  grep -Eq 'concurrent CPU/DMA iterations: [1-9][0-9]*' "$build_dir/$stem.log"
}

if [[ $mode == baseline ]]; then
  run_sim run
  check_clean_run run

  run_sim run-stalls +AXI_STALLS
  check_clean_run run-stalls
  grep -q 'mode: axi_stalls=1 dma_reset=0' "$build_dir/run-stalls.log"

  run_sim run-reset +AXI_STALLS +DMA_RESET
  check_clean_run run-reset
  grep -q 'injected SoC reset while iDMA busy' "$build_dir/run-reset.log"

  python3 - "$build_dir/run.log" "$build_dir/run-stalls.log" \
      "$build_dir/run-reset.log" <<'PY'
import re
import sys

activity_re = re.compile(
    r"DMA activity: jobs=(\d+)/(\d+) busy_cycles=(\d+) "
    r"ar=(\d+) aw=(\d+) r=(\d+) w=(\d+) b=(\d+)"
)
wait_re = re.compile(r"AXI wait cycles: aw=(\d+) w=(\d+) b=(\d+) ar=(\d+) r=(\d+)")

def parse(path):
    text = open(path, encoding="utf-8").read()
    activity = tuple(map(int, activity_re.search(text).groups()))
    waits = tuple(map(int, wait_re.search(text).groups()))
    return activity, waits

normal, stalled, reset = map(parse, sys.argv[1:])
if normal[0][0:2] != (30, 30) or stalled[0][0:2] != (30, 30) or reset[0][0:2] != (30, 30):
    raise SystemExit("job accounting mismatch")
if normal[0][3:] != stalled[0][3:] or stalled[0][3:] != reset[0][3:]:
    raise SystemExit("AXI transfer counts changed across timing/reset controls")
if stalled[0][2] <= normal[0][2]:
    raise SystemExit("deterministic stalls did not increase DMA busy time")
if not all(after > before for before, after in zip(normal[1], stalled[1])):
    raise SystemExit("deterministic stalls did not increase every AXI wait counter")
print("PASS: identical DMA transfers under normal, stalled and reset-recovery runs")
PY
  echo "PASS: CVA6 executed the 30-job boundary/2D/concurrency DMA matrix"
else
  run_sim run +AXI_STALLS
  [[ $sim_rc -ne 0 ]]
  grep -q 'CVA6 DMA firmware failed: code 4097' "$build_dir/run.log"
  echo "PASS: CVA6 detected the injected first-case iDMA write corruption"
fi

