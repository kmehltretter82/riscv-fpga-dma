#!/usr/bin/env bash
set -euo pipefail

mode=${1:-smoke}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd -- "$script_dir/.." && pwd)
cheshire_dir="$workspace/cheshire"
idma_repo="$workspace/idma"
tools_dir="$workspace/.tools"
bender_db="$workspace/.cache/bender-db"
idma_commit=ff5d56fffb3767814db88d6bf8f381974ea33aa5
baseline_build="$script_dir/build-random"
fault_build="$script_dir/build-random-fault"
fault_tree="$script_dir/.idma-fault-random"
fault_worktree=0

usage() {
  cat <<EOF
usage:
  $0 build
  $0 smoke
  $0 campaign
  $0 data-fault
  $0 cell STEM SEED COUNT {direct|fixed|random} \
       [clean|reset|read-error|write-error] [ERROR_JOB] [ERROR_BURST]

Environment:
  BUILD_JOBS=N       C++ build parallelism (default: 6)
  CAMPAIGN_CASES=N   descriptors per campaign cell (default: 128)
  CAMPAIGN_JOBS=N    concurrent simulations (default: 6)
  SKIP_CASES=N       generate/hash the prefix but execute from case N
  EXEC_MASK=HEX      execute selected cases relative to SKIP_CASES
  MODEL_BUILD=PATH   use an already-built model for cell/smoke/campaign
  REBUILD=1          force Verilator regeneration
  RESULT_DIR=PATH    output directory for smoke, campaign, or cell
EOF
}

cleanup() {
  if [[ $fault_worktree == 1 && ${KEEP_WORKTREE:-0} != 1 ]]; then
    git -C "$idma_repo" worktree remove --force "$fault_tree" \
      >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

export BENDER_DB_DIR="$bender_db"
export BENDER_LOCAL=true

require_dependencies() {
  if [[ ! -d "$cheshire_dir/.bender/git/checkouts" ]] ||
     ! "$tools_dir/bin/bender" -d "$cheshire_dir" path axi >/dev/null 2>&1 ||
     ! "$tools_dir/bin/bender" -d "$cheshire_dir" path idma >/dev/null 2>&1; then
    cat >&2 <<EOF
Locked Cheshire dependencies are absent. Restore them with:
  BENDER_DB_DIR=$bender_db \\
    $tools_dir/bin/bender -d $cheshire_dir checkout --no-progress
EOF
    exit 2
  fi
}

generate_sources() {
  "$tools_dir/bin/bender" -d "$cheshire_dir" script verilator \
    -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb > "$script_dir/sources.f"
}

build_model() {
  local build_dir=$1
  local sources=$2
  local simv="$build_dir/simv"

  if [[ ${REBUILD:-0} != 1 && -x $simv &&
        $simv -nt "$script_dir/tb_cheshire_cva6_dma_random.sv" &&
        $simv -nt "$script_dir/axi_bounded_delayer.sv" &&
        $simv -nt "$script_dir/axi_sim_mem_reset.sv" ]]; then
    return
  fi

  mkdir -p -- "$build_dir/obj_dir"
  set +e
  /usr/bin/time -v "$tools_dir/verilator-5.052/bin/verilator" \
    --binary --assert --timing --timescale 1ns/1ps \
    -Wno-fatal --error-limit 1000 \
    -f "$sources" "$script_dir/axi_sim_mem_reset.sv" \
    "$script_dir/axi_bounded_delayer.sv" \
    "$script_dir/tb_cheshire_cva6_dma_random.sv" \
    --top-module tb_cheshire_cva6_dma_random \
    --Mdir "$build_dir/obj_dir" -o ../simv \
    --build-jobs "${BUILD_JOBS:-6}" \
    > "$build_dir/build.log" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "$rc" > "$build_dir/build.exit"
  if (( rc != 0 )); then
    tail -100 "$build_dir/build.log" >&2
    return "$rc"
  fi
}

prepare_baseline() {
  require_dependencies
  "$script_dir/fw/build.sh"
  generate_sources
  build_model "$baseline_build" "$script_dir/sources.f"
}

normalize_seed() {
  python3 - "$1" <<'PY'
import sys
print(f"{int(sys.argv[1], 0) & 0xffffffff:08x}")
PY
}

timing_seed_for() {
  python3 - "$1" <<'PY'
import sys
print(f"{(int(sys.argv[1], 16) ^ 0x9e3779b9) & 0xffffffff:08x}")
PY
}

run_cell() {
  local build_dir=$1
  local out_dir=$2
  local stem=$3
  local seed_arg=$4
  local count=$5
  local timing=$6
  local scenario=${7:-clean}
  local error_job=${8:-0}
  local error_burst=${9:-0}
  local expect_fault=${10:-0}
  local seed_hex timing_seed expected_hash sim_rc timeout_cycles profile
  local skip_cases execute_mask_hex
  local -a extra=()

  seed_hex=$(normalize_seed "$seed_arg")
  timing_seed=$(timing_seed_for "$seed_hex")
  profile=${GEOMETRY_PROFILE:-full}
  case "$profile" in
    full) ;;
    duration) extra+=(+PROFILE_DURATION) ;;
    *) echo "unknown geometry profile: $profile" >&2; return 2 ;;
  esac
  expected_hash=$("$script_dir/cases.py" --seed "0x$seed_hex" \
    --count "$count" --profile "$profile" --hash-only)
  skip_cases=${SKIP_CASES:-0}
  execute_mask_hex=$(normalize_seed "${EXEC_MASK:-0}")
  [[ $skip_cases =~ ^[0-9]+$ ]] && (( skip_cases <= count )) || {
    echo "SKIP_CASES must be an integer in 0..COUNT" >&2
    return 2
  }
  timeout_cycles=${TIMEOUT_CYCLES:-$((20000000 + count * 4000000))}
  mkdir -p -- "$out_dir"
  "$script_dir/cases.py" --seed "0x$seed_hex" --count "$count" \
    --profile "$profile" \
    --tsv "$out_dir/$stem.cases.tsv" \
    --summary "$out_dir/$stem.cases.json" >/dev/null

  case "$timing" in
    direct) ;;
    fixed) extra+=(+AXI_FIXED) ;;
    random) extra+=(+AXI_RANDOM) ;;
    *) echo "unknown timing mode: $timing" >&2; return 2 ;;
  esac
  case "$scenario" in
    clean) ;;
    reset) extra+=(+DMA_RESET) ;;
    read-error)
      extra+=(+READ_ERROR "+ERROR_JOB=$error_job" "+ERROR_BURST=$error_burst")
      ;;
    write-error)
      extra+=(+WRITE_ERROR "+ERROR_JOB=$error_job" "+ERROR_BURST=$error_burst")
      ;;
    *) echo "unknown scenario: $scenario" >&2; return 2 ;;
  esac

  set +e
  /usr/bin/time -v "$build_dir/simv" \
    "+MEMH=$script_dir/fw/dma_random_test.memh" \
    "+SEED=$seed_hex" "+CASES=$count" \
    "+SKIP_CASES=$skip_cases" \
    "+EXEC_MASK=$execute_mask_hex" \
    "+TIMING_SEED=$timing_seed" "+EXPECT_HASH=$expected_hash" \
    "+TIMEOUT_CYCLES=$timeout_cycles" \
    "${extra[@]}" > "$out_dir/$stem.log" 2>&1
  sim_rc=$?
  set -e
  printf '%s\n' "$sim_rc" > "$out_dir/$stem.exit"

  if (( expect_fault )); then
    [[ $sim_rc -ne 0 ]]
    grep -q 'CVA6 random DMA firmware failed:' "$out_dir/$stem.log"
    grep -Eq 'diagnostic: .*index=0 .*reason=(2|6) ' "$out_dir/$stem.log"
    echo "PASS $stem: firmware oracle detected injected iDMA corruption"
  else
    [[ $sim_rc -eq 0 ]]
    grep -q '\[TB\] CVA6+iDMA randomized campaign PASS' "$out_dir/$stem.log"
    grep -q "completion: .* completed=$count rc=0" "$out_dir/$stem.log"
    grep -q "diagnostic: .*seed=0x$seed_hex requested=$count completed=$count .*hash=0x$expected_hash" \
      "$out_dir/$stem.log"
    if [[ $scenario == read-error ]]; then
      grep -Eq 'AXI errors: read=[1-9][0-9]* write=0 injected=1' \
        "$out_dir/$stem.log"
    elif [[ $scenario == write-error ]]; then
      grep -Eq 'AXI errors: read=0 write=[1-9][0-9]* injected=1' \
        "$out_dir/$stem.log"
    fi
    echo "PASS $stem: seed=0x$seed_hex count=$count hash=0x$expected_hash"
  fi
}

summarize() {
  local out_dir=$1
  python3 - "$out_dir" <<'PY'
import csv
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
activity = re.compile(
    r"DMA activity: jobs=(\d+)/(\d+) busy_cycles=(\d+) "
    r"ar=(\d+) aw=(\d+) r=(\d+) w=(\d+) b=(\d+)"
)
waits = re.compile(r"AXI wait cycles: aw=(\d+) w=(\d+) b=(\d+) ar=(\d+) r=(\d+)")
errors = re.compile(r"AXI errors: read=(\d+) write=(\d+) injected=(\d+)")
rows = []
for summary_path in sorted(root.glob("*.cases.json")):
    stem = summary_path.name.removesuffix(".cases.json")
    log_path = root / f"{stem}.log"
    exit_path = root / f"{stem}.exit"
    if not log_path.exists() or not exit_path.exists():
        raise SystemExit(f"missing result for {stem}")
    summary = json.loads(summary_path.read_text())
    text = log_path.read_text(errors="replace")
    am = activity.search(text)
    wm = waits.search(text)
    em = errors.search(text)
    if not (am and wm and em):
        raise SystemExit(f"missing counters in {log_path}")
    rows.append({
        "stem": stem,
        "seed": summary["seed_hex"],
        "cases": summary["count"],
        "hash": summary["descriptor_hash_hex"],
        "one_d": summary["one_d"],
        "two_d": summary["two_d"],
        "src_page_cross": summary["source_page_crossings"],
        "dst_page_cross": summary["destination_page_crossings"],
        "exit": int(exit_path.read_text()),
        "issues": int(am.group(1)),
        "retires": int(am.group(2)),
        "busy_cycles": int(am.group(3)),
        "read_errors": int(em.group(1)),
        "write_errors": int(em.group(2)),
        "aw_wait": int(wm.group(1)),
        "w_wait": int(wm.group(2)),
        "b_wait": int(wm.group(3)),
        "ar_wait": int(wm.group(4)),
        "r_wait": int(wm.group(5)),
    })
with (root / "results.tsv").open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
print(f"wrote {root / 'results.tsv'} with {len(rows)} cells")
PY
}

run_smoke() {
  local model=${1:-$baseline_build}
  local out_dir=${RESULT_DIR:-"$script_dir/results/smoke"}
  run_cell "$model" "$out_dir" direct 0x12345678 16 direct clean
  run_cell "$model" "$out_dir" fixed 0x12345678 16 fixed clean
  run_cell "$model" "$out_dir" random 0x12345678 16 random clean
  run_cell "$model" "$out_dir" reset 0x12345678 16 random reset
  run_cell "$model" "$out_dir" read-error 0x12345678 16 random read-error 8 0
  run_cell "$model" "$out_dir" write-error 0x12345678 16 random write-error 8 0
  summarize "$out_dir"
}

run_campaign() {
  local model=${1:-$baseline_build}
  local count=${CAMPAIGN_CASES:-128}
  local max_jobs=${CAMPAIGN_JOBS:-6}
  local out_dir=${RESULT_DIR:-"$script_dir/results/campaign-$count"}
  local failed=0
  local -a pids=()
  local -a seeds=(
    0x00000001 0x12345678 0xdeadbeef 0xc001d00d
    0x31415926 0x80000001 0xffffffff 0x6d2b79f5
  )
  mkdir -p -- "$out_dir"
  trap '
    trap - INT TERM HUP
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    exit 130
  ' INT TERM HUP
  for seed in "${seeds[@]}"; do
    for timing in direct fixed random; do
      stem="${timing}-${seed#0x}"
      (GEOMETRY_PROFILE=duration run_cell "$model" "$out_dir" "$stem" "$seed" \
        "$count" "$timing" clean > "$out_dir/$stem.driver.log" 2>&1) &
      pids+=("$!")
      if (( ${#pids[@]} >= max_jobs )); then
        wait "${pids[0]}" || failed=1
        pids=("${pids[@]:1}")
      fi
    done
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  pids=()
  (( failed == 0 )) || return 1

  pids=()
  (GEOMETRY_PROFILE=duration run_cell "$model" "$out_dir" reset-deadbeef \
    0xdeadbeef "$count" random reset) &
  pids+=("$!")
  (GEOMETRY_PROFILE=duration run_cell "$model" "$out_dir" read-error-c001d00d \
    0xc001d00d "$count" random read-error "$((count / 2))" 0) &
  pids+=("$!")
  (GEOMETRY_PROFILE=duration run_cell "$model" "$out_dir" write-error-31415926 \
    0x31415926 "$count" random write-error "$((count / 2))" 0) &
  pids+=("$!")
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  pids=()
  trap - INT TERM HUP
  (( failed == 0 )) || return 1
  summarize "$out_dir"
}

prepare_fault_model() {
  if [[ -e $fault_tree ]]; then
    git -C "$idma_repo" worktree remove --force "$fault_tree"
  fi
  git -C "$idma_repo" worktree add --detach "$fault_tree" "$idma_commit"
  fault_worktree=1
  git -C "$fault_tree" apply "$script_dir/fault-corrupt-final-write.patch"
  local idma_dep
  idma_dep=$("$tools_dir/bin/bender" -d "$cheshire_dir" path idma)
  sed "s|$idma_dep|$fault_tree|g" "$script_dir/sources.f" \
    > "$script_dir/sources-fault.f"
  REBUILD=1 build_model "$fault_build" "$script_dir/sources-fault.f"
}

case "$mode" in
  build)
    prepare_baseline
    ;;
  cell)
    (( $# >= 5 )) || { usage >&2; exit 2; }
    prepare_baseline
    out_dir=${RESULT_DIR:-"$script_dir/results/cell"}
    run_cell "${MODEL_BUILD:-$baseline_build}" "$out_dir" "$2" "$3" "$4" "$5" \
      "${6:-clean}" "${7:-0}" "${8:-0}"
    ;;
  smoke)
    prepare_baseline
    run_smoke "${MODEL_BUILD:-$baseline_build}"
    ;;
  campaign)
    prepare_baseline
    run_campaign "${MODEL_BUILD:-$baseline_build}"
    ;;
  data-fault)
    prepare_baseline
    prepare_fault_model
    out_dir=${RESULT_DIR:-"$script_dir/results/data-fault"}
    run_cell "$fault_build" "$out_dir" corrupt-first-write \
      0x12345678 16 random clean 0 0 1
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
