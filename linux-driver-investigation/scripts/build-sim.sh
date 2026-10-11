#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
cheshire="$workspace/cheshire"
idma="$workspace/idma"
cheshire_variant="$here/sources/cheshire-irq"
idma_variant="$here/sources/idma-abort"
cva6_variant="$here/sources/cva6-no-trace"
tools="$workspace/.tools"
build="$here/build/sim-irq"

check_revision() {
  local tree=$1 expected=$2 label=$3 actual
  actual=$(git -C "$tree" rev-parse HEAD)
  if [[ $actual != "$expected" ]]; then
    printf '%s revision mismatch: expected %s, got %s\n' \
      "$label" "$expected" "$actual" >&2
    exit 2
  fi
}

check_revision "$cheshire" \
  292d2c091ffed3e194b0f437b5b3460813905e26 Cheshire
check_revision "$cheshire_variant" \
  292d2c091ffed3e194b0f437b5b3460813905e26 Cheshire-error-worktree
check_revision "$idma_variant" \
  ff5d56fffb3767814db88d6bf8f381974ea33aa5 iDMA-error-worktree
check_revision "$cva6_variant" \
  4c02b24fe7c04690f626776a92274da24f80d1da CVA6-no-trace-worktree

git -C "$cheshire_variant" diff --quiet -- \
  ':!hw/cheshire_idma_wrap.sv' ':!hw/cheshire_pkg.sv' ':!hw/cheshire_soc.sv' || {
  printf 'Unexpected Cheshire IRQ-worktree modifications\n' >&2
  exit 2
}

export BENDER_DB_DIR="$workspace/.cache/bender-db"
export BENDER_LOCAL=true

rm -rf -- "$build"
mkdir -p -- "$build"
"$tools/bin/bender" -d "$cheshire" script verilator \
  -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb > "$build/sources-base.f"
axi_dir=$("$tools/bin/bender" -d "$cheshire" path axi)
idma_base=$("$tools/bin/bender" -d "$cheshire" path idma)
cva6_base=$("$tools/bin/bender" -d "$cheshire" path cva6)

python3 - "$build/sources-base.f" "$build/sources.f" \
    "$cheshire" "$cheshire_variant" "$idma_base" "$idma_variant" \
    "$cva6_base" "$cva6_variant" <<'PY'
from pathlib import Path
import sys

(src, dst, cheshire, cheshire_variant, idma, idma_variant,
 cva6, cva6_variant) = map(Path, sys.argv[1:])
text = src.read_text()

replacements = (
    (cheshire / "hw/cheshire_idma_wrap.sv",
     cheshire_variant / "hw/cheshire_idma_wrap.sv"),
    (cheshire / "hw/cheshire_pkg.sv",
     cheshire_variant / "hw/cheshire_pkg.sv"),
    (cheshire / "hw/cheshire_soc.sv",
     cheshire_variant / "hw/cheshire_soc.sv"),
    (idma, idma_variant),
    (cva6 / "core/cva6.sv", cva6_variant / "core/cva6.sv"),
)
for old, new in replacements:
    old_text = str(old)
    count = text.count(old_text)
    if old.is_dir() and old.name != "cva6.sv":
        if count == 0:
            raise SystemExit(f"source-list path absent: {old}")
    elif count != 1:
        raise SystemExit(f"expected one source-list occurrence of {old}, got {count}")
    text = text.replace(old_text, str(new))
dst.write_text(text)
PY

/usr/bin/time -v "$tools/verilator-5.052/bin/verilator" \
  --binary --assert --timing --timescale 1ns/1ps \
  -Wno-fatal --error-limit 1000 \
  -f "$build/sources.f" "$axi_dir/src/axi_sim_mem.sv" \
  "$here/rtl/tb_cheshire_linux_dma_irq.sv" \
  --top-module tb_cheshire_linux_dma_irq \
  --Mdir "$build/obj_dir" -o ../simv \
  --build-jobs "${BUILD_JOBS:-4}" \
  > "$build/build.log" 2>&1
printf '0\n' > "$build/build.exit"
printf 'Built %s\n' "$build/simv"
