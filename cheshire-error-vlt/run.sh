#!/usr/bin/env bash
set -euo pipefail

variant=${1:-production}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
workspace=$(cd -- "$script_dir/.." && pwd)
cheshire_dir="$workspace/cheshire"
idma_repo="$workspace/idma"
tools_dir="$workspace/.tools"
bender_db="$workspace/.cache/bender-db"
cheshire_commit=292d2c091ffed3e194b0f437b5b3460813905e26
idma_commit=ff5d56fffb3767814db88d6bf8f381974ea33aa5
variant_tree="$script_dir/.cheshire-$variant"
idma_tree="$script_dir/.idma-$variant"
variant_worktree=0
idma_worktree=0

case "$variant" in
  production|autoabort-naive|autoabort-fixed|autoabort-handshake|autoabort-drain) ;;
  *) echo "usage: $0 {production|autoabort-naive|autoabort-fixed|autoabort-handshake|autoabort-drain}" >&2; exit 2 ;;
esac

cleanup() {
  if [[ $variant_worktree == 1 && ${KEEP_WORKTREE:-0} != 1 ]]; then
    git -C "$cheshire_dir" worktree remove --force "$variant_tree" \
      >/dev/null 2>&1 || true
  fi
  if [[ $idma_worktree == 1 && ${KEEP_WORKTREE:-0} != 1 ]]; then
    git -C "$idma_repo" worktree remove --force "$idma_tree" \
      >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

export BENDER_DB_DIR="$bender_db"
export BENDER_LOCAL=true

if [[ ! -d "$cheshire_dir/.bender/git/checkouts" ||
      ! -d "$bender_db/git/db" ]] ||
   ! "$tools_dir/bin/bender" -d "$cheshire_dir" path axi >/dev/null 2>&1; then
  cat >&2 <<EOF
Locked Cheshire dependencies are absent. Restore them with:
  cd $workspace
  BENDER_DB_DIR=$bender_db \
    $tools_dir/bin/bender -d $cheshire_dir checkout --no-progress
Then rerun this command. The retained Cheshire Bender.lock selects exact revisions.
EOF
  exit 2
fi

"$script_dir/fw/build.sh"

base_sources="$script_dir/sources-production.f"
"$tools_dir/bin/bender" -d "$cheshire_dir" script verilator \
  -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb > "$base_sources"
sources="$base_sources"

if [[ $variant != production ]]; then
  if [[ -e $variant_tree ]]; then
    git -C "$cheshire_dir" worktree remove --force "$variant_tree"
  fi
  git -C "$cheshire_dir" worktree add --detach "$variant_tree" "$cheshire_commit"
  variant_worktree=1
  git -C "$variant_tree" apply "$script_dir/$variant.patch"
  if [[ -e $idma_tree ]]; then
    git -C "$idma_repo" worktree remove --force "$idma_tree"
  fi
  git -C "$idma_repo" worktree add --detach "$idma_tree" "$idma_commit"
  idma_worktree=1
  git -C "$idma_tree" apply "$script_dir/verilator-error-handler-compat.patch"
  if [[ $variant == autoabort-drain ]]; then
    git -C "$idma_tree" apply "$script_dir/idma-error-drain.patch"
  fi
  idma_dep=$("$tools_dir/bin/bender" -d "$cheshire_dir" path idma)
  sources="$script_dir/sources-$variant.f"
  python3 - "$base_sources" "$sources" \
      "$cheshire_dir" "$variant_tree" "$idma_dep" "$idma_tree" <<'PY'
from pathlib import Path
import sys

src, dst, base, variant, idma_base, idma_variant = map(Path, sys.argv[1:])
old = str(base / "hw/cheshire_idma_wrap.sv")
new = str(variant / "hw/cheshire_idma_wrap.sv")
text = src.read_text()
count = text.count(old)
if count != 1:
    raise SystemExit(f"expected one Cheshire wrapper path, found {count}")
text = text.replace(old, new)
idma_count = text.count(str(idma_base))
if idma_count == 0:
    raise SystemExit("locked iDMA path is absent from the source list")
dst.write_text(text.replace(str(idma_base), str(idma_variant)))
PY
fi

build_dir="$script_dir/build-$variant"
rm -rf -- "$build_dir"
mkdir -p -- "$build_dir"

/usr/bin/time -v "$tools_dir/verilator-5.052/bin/verilator" \
  --binary --assert --timing --timescale 1ns/1ps \
  -Wno-fatal --error-limit 1000 \
  -f "$sources" "$script_dir/axi_sim_mem_reset.sv" \
  "$script_dir/tb_cheshire_dma_error.sv" \
  --top-module tb_cheshire_dma_error \
  --Mdir "$build_dir/obj_dir" -o ../simv \
  --build-jobs "${BUILD_JOBS:-6}" \
  > "$build_dir/build.log" 2>&1
printf '0\n' > "$build_dir/build.exit"

run_sim() {
  local stem=$1
  shift
  set +e
  /usr/bin/time -v "$build_dir/simv" \
    "+MEMH=$script_dir/fw/dma_error_test.memh" "$@" \
    > "$build_dir/$stem.log" 2>&1
  sim_rc=$?
  set -e
  printf '%s\n' "$sim_rc" > "$build_dir/$stem.exit"
  cat "$build_dir/$stem.log"
}

check_pass() {
  local stem=$1
  [[ $sim_rc -eq 0 ]]
  grep -q '\[TB\] CVA6+iDMA error-policy PASS' "$build_dir/$stem.log"
  grep -q '\[TB\] DMA activity: jobs=2/2' "$build_dir/$stem.log"
  grep -q '\[TB\] IDs: done=3 next=4' "$build_dir/$stem.log"
}

check_clean() {
  local stem=$1
  check_pass "$stem"
  grep -q 'completion: .* prefix=4097 rc=0' "$build_dir/$stem.log"
  grep -q 'AXI errors: read=0 write=0 injected=0' "$build_dir/$stem.log"
  grep -q 'backend_err=0' "$build_dir/$stem.log"
}

case "$variant" in
  production)
    run_sim clean
    check_clean clean

    run_sim read-error +AXI_STALLS +READ_ERROR +EXPECT_CONTINUE
    check_pass read-error
    grep -q 'completion: .* prefix=4097 rc=0' "$build_dir/read-error.log"
    grep -Eq 'AXI errors: read=[1-9][0-9]* write=0 injected=1' \
      "$build_dir/read-error.log"
    grep -q 'backend_err=0' "$build_dir/read-error.log"

    run_sim write-error +AXI_STALLS +WRITE_ERROR +EXPECT_CONTINUE
    check_pass write-error
    grep -q 'completion: .* prefix=4097 rc=0' "$build_dir/write-error.log"
    grep -Eq 'AXI errors: read=0 write=[1-9][0-9]* injected=1' \
      "$build_dir/write-error.log"
    grep -q 'backend_err=0' "$build_dir/write-error.log"
    echo "PASS: production NO_ERROR_HANDLING continued after read and write SLVERR"
    ;;

  autoabort-naive)
    run_sim clean
    check_clean clean

    run_sim read-error +AXI_STALLS +READ_ERROR +EXPECT_ABORT
    printf 'naive_read_error_rc=%s\n' "$sim_rc"
    run_sim write-error +AXI_STALLS +WRITE_ERROR +EXPECT_ABORT
    printf 'naive_write_error_rc=%s\n' "$sim_rc"
    echo "DONE: naive auto-abort error runs captured for characterization"
    ;;

  autoabort-fixed)
    run_sim clean
    check_clean clean

    run_sim read-error +AXI_STALLS +READ_ERROR +EXPECT_ABORT
    printf 'filtered_read_error_rc=%s\n' "$sim_rc"

    run_sim write-error +AXI_STALLS +WRITE_ERROR +EXPECT_ABORT
    printf 'filtered_write_error_rc=%s\n' "$sim_rc"
    echo "DONE: error-filter-only runs captured for characterization"
    ;;

  autoabort-handshake)
    run_sim clean
    check_clean clean

    run_sim read-error +AXI_STALLS +READ_ERROR +EXPECT_ABORT
    printf 'handshake_read_error_rc=%s\n' "$sim_rc"

    run_sim write-error +AXI_STALLS +WRITE_ERROR +EXPECT_ABORT
    printf 'handshake_write_error_rc=%s\n' "$sim_rc"
    echo "DONE: sequenced-handshake runs captured for characterization"
    ;;

  autoabort-drain)
    run_sim clean
    check_clean clean

    run_sim read-error +AXI_STALLS +READ_ERROR +EXPECT_ABORT
    check_pass read-error
    grep -Eq 'completion: .* prefix=([0-9]|[1-3][0-9]{1,3}|40[0-8][0-9]|409[0-6]) rc=0' \
      "$build_dir/read-error.log"
    grep -Eq 'AXI errors: read=[1-9][0-9]* write=0 injected=1' \
      "$build_dir/read-error.log"
    grep -Eq 'backend_err=[1-9][0-9]*' "$build_dir/read-error.log"

    run_sim write-error +AXI_STALLS +WRITE_ERROR +EXPECT_ABORT
    check_pass write-error
    grep -Eq 'completion: .* prefix=([0-9]|[1-3][0-9]{1,3}|40[0-8][0-9]|409[0-6]) rc=0' \
      "$build_dir/write-error.log"
    grep -Eq 'AXI errors: read=0 write=[1-9][0-9]* injected=1' \
      "$build_dir/write-error.log"
    grep -Eq 'backend_err=[1-9][0-9]*' "$build_dir/write-error.log"

    run_sim post-error-clean +AXI_STALLS
    check_clean post-error-clean
    echo "PASS: response drain plus sequenced error/action handshakes recovered from read and write aborts"
    ;;
esac
