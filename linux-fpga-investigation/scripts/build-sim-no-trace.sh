#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
cheshire="$workspace/cheshire"
tools="$workspace/.tools"
build="$here/build/sim-no-trace"
cva6_variant="$here/sources/cva6-no-trace"
cheshire_commit=292d2c091ffed3e194b0f437b5b3460813905e26
cva6_commit=4c02b24fe7c04690f626776a92274da24f80d1da

[[ $(git -C "$cheshire" rev-parse HEAD) == "$cheshire_commit" ]] || {
  printf 'Unexpected Cheshire revision\n' >&2
  exit 2
}

export BENDER_DB_DIR="$workspace/.cache/bender-db"
export BENDER_LOCAL=true
cva6_base=$("$tools/bin/bender" -d "$cheshire" path cva6)

if [[ ! -e $cva6_variant/.git ]]; then
  git -C "$cva6_base" worktree add --detach "$cva6_variant" "$cva6_commit"
  git -C "$cva6_variant" apply \
    "$here/patches/cva6-verilator-optional-dasm-trace.patch"
fi
[[ $(git -C "$cva6_variant" rev-parse HEAD) == "$cva6_commit" ]] || {
  printf 'Unexpected CVA6 no-trace worktree revision\n' >&2
  exit 2
}
git -C "$cva6_variant" apply --reverse --check \
  "$here/patches/cva6-verilator-optional-dasm-trace.patch"
unexpected=$(git -C "$cva6_variant" status --short | \
  sed '/^ M core\/cva6\.sv$/d')
[[ -z $unexpected ]] || {
  printf 'Unexpected CVA6 no-trace worktree changes:\n%s\n' "$unexpected" >&2
  exit 2
}

rm -rf -- "$build"
mkdir -p -- "$build"
"$tools/bin/bender" -d "$cheshire" script verilator \
  -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb > "$build/sources-base.f"
axi_dir=$("$tools/bin/bender" -d "$cheshire" path axi)

python3 - "$build/sources-base.f" "$build/sources.f" \
    "$cva6_base/core/cva6.sv" "$cva6_variant/core/cva6.sv" <<'PY'
from pathlib import Path
import sys

src, dst, old, new = map(Path, sys.argv[1:])
text = src.read_text()
if text.count(str(old)) != 1:
    raise SystemExit(f"expected one source-list occurrence of {old}")
dst.write_text(text.replace(str(old), str(new)))
PY

/usr/bin/time -v "$tools/verilator-5.052/bin/verilator" \
  --binary --assert --timing --timescale 1ns/1ps \
  -Wno-fatal --error-limit 1000 \
  -f "$build/sources.f" "$axi_dir/src/axi_sim_mem.sv" \
  "$here/rtl/tb_cheshire_linux_dma.sv" \
  --top-module tb_cheshire_linux_dma \
  --Mdir "$build/obj_dir" -o ../simv \
  --build-jobs "${BUILD_JOBS:-4}" \
  > "$build/build.log" 2>&1
printf '0\n' > "$build/build.exit"
printf 'Built %s\n' "$build/simv"
