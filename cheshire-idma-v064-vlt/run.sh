#!/usr/bin/env bash
set -euo pipefail

mode=${1:-baseline}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd -- "$script_dir/.." && pwd)
idma_repo="$workspace/idma"
pin_tree="$workspace/idma-cheshire-pin"
cheshire_tree="$workspace/cheshire"
tools_dir="$workspace/.tools"
base_commit=ff5d56fffb3767814db88d6bf8f381974ea33aa5
source_tree="$pin_tree"
wrapper_tree="$cheshire_tree"
idma_worktree=0
cheshire_worktree=0
verilator_mode_args=()

case "$mode" in
  baseline) ;;
  data-fault)
    source_tree="$script_dir/.worktree-data-fault"
    if [[ -e $source_tree ]]; then
      git -C "$idma_repo" worktree remove --force "$source_tree"
    fi
    git -C "$idma_repo" worktree add --detach "$source_tree" "$base_commit"
    idma_worktree=1
    ln -s "$pin_tree/.bender" "$source_tree/.bender"
    git -C "$source_tree" apply "$script_dir/fault-corrupt-final-write.patch"
    ;;
  one-d-unpatched)
    verilator_mode_args+=( -GDutTwoD=0 )
    ;;
  one-d-fixed)
    wrapper_tree="$script_dir/.cheshire-worktree-fix"
    if [[ -e $wrapper_tree ]]; then
      git -C "$cheshire_tree" worktree remove --force "$wrapper_tree"
    fi
    git -C "$cheshire_tree" worktree add --detach "$wrapper_tree" HEAD
    cheshire_worktree=1
    git -C "$wrapper_tree" apply "$script_dir/fix-1d-busy-signal.patch"
    verilator_mode_args+=( -GDutTwoD=0 -Werror-IMPLICIT )
    ;;
  *) echo "usage: $0 {baseline|data-fault|one-d-unpatched|one-d-fixed}" >&2; exit 2 ;;
esac

cleanup() {
  if [[ $idma_worktree == 1 && ${KEEP_WORKTREE:-0} != 1 ]]; then
    git -C "$idma_repo" worktree remove --force "$source_tree" >/dev/null 2>&1 || true
  fi
  if [[ $cheshire_worktree == 1 && ${KEEP_WORKTREE:-0} != 1 ]]; then
    git -C "$cheshire_tree" worktree remove --force "$wrapper_tree" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

build_dir="$script_dir/build/$mode"
rm -rf -- "$build_dir"
mkdir -p -- "$build_dir"
export BENDER_DB_DIR="$idma_repo/.bender/git/db"
export BENDER_LOCAL=true

"$tools_dir/bin/bender" -d "$source_tree" script verilator -t rtl > "$build_dir/sources.f"

"$tools_dir/verilator-5.052/bin/verilator" \
  --binary --assert --timing --timescale 1ns/1ps \
  -Wno-fatal --error-limit 1000 \
  -f "$build_dir/sources.f" \
  "$wrapper_tree/hw/cheshire_idma_wrap.sv" \
  "$script_dir/tb_cheshire_idma_wrap.sv" \
  --top-module tb_cheshire_idma_wrap \
  "${verilator_mode_args[@]}" \
  --Mdir "$build_dir/obj_dir" -o "$build_dir/simv" --build-jobs 6 \
  > "$build_dir/build.log" 2>&1

run_one() {
  local name=$1
  shift
  set +e
  /usr/bin/time -v "$build_dir/simv" "$@" > "$build_dir/$name.log" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "$rc" > "$build_dir/$name.exit"
  cat "$build_dir/$name.log"
  return "$rc"
}

case "$mode" in
  baseline)
    run_one run
    grep -q '\[TB\] 1D PASS:' "$build_dir/run.log"
    grep -q '\[TB\] 2D PASS:' "$build_dir/run.log"
    grep -q '\[TB\] ALL PASS: exact Cheshire iDMA v0.6.4 wrapper' "$build_dir/run.log"
    ;;
  data-fault)
    if run_one run-1d +only1d; then
      echo "data fault unexpectedly passed the 1D oracle" >&2
      exit 1
    fi
    grep -q '1D payload mismatch at 2040: expected 0xe3 got 0xe2' "$build_dir/run-1d.log"

    if run_one run-2d +only2d; then
      echo "data fault unexpectedly passed the 2D oracle" >&2
      exit 1
    fi
    grep -q '2D mismatch at offset 8:' "$build_dir/run-2d.log"
    echo "PASS: protocol-valid final-write corruption detected by both 1D and 2D payload oracles"
    ;;
  one-d-unpatched)
    grep -q "Signal definition not found, creating implicitly: 'idma_busy'" "$build_dir/build.log"
    if run_one run +only1d; then
      echo "unpatched 1D wrapper unexpectedly reported valid busy status" >&2
      exit 1
    fi
    grep -q '1D status did not report busy after launch' "$build_dir/run.log"
    echo "PASS: reproduced undeclared idma_busy and the resulting false-idle 1D status"
    ;;
  one-d-fixed)
    run_one run +only1d
    grep -q '\[TB\] 1D PASS:' "$build_dir/run.log"
    grep -q '\[TB\] ALL PASS: exact Cheshire iDMA v0.6.4 wrapper' "$build_dir/run.log"
    if grep -q "creating implicitly: 'idma_busy'" "$build_dir/build.log"; then
      echo "fixed wrapper still contains an implicit idma_busy net" >&2
      exit 1
    fi
    echo "PASS: fixed 1D wrapper reports busy and completes the guarded copy"
    ;;
esac
