#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
cheshire="$workspace/cheshire"
cheshire_variant="$here/sources/cheshire-irq"
idma_variant="$here/sources/idma-abort"
cva6_variant="$here/sources/cva6-no-trace"
tools="$workspace/.tools"
cell=${CELL:-}

case "$cell" in
  legacy)
    target=cv64a6_imafdchsclic_sv39_wb
    define=()
    ;;
  hpd)
    target=cv64a6_imafdchsclic_sv39_hpdcache
    define=(-DPHASE11_HPDCACHE)
    ;;
  *)
    printf 'CELL must be legacy or hpd\n' >&2
    exit 2
    ;;
esac
build="$here/build/sim-$cell"
"$here/scripts/check-source-contracts.sh"

export BENDER_DB_DIR="$workspace/.cache/bender-db"
export BENDER_LOCAL=true
rm -rf -- "$build"
mkdir -p -- "$build"
"$tools/bin/bender" -d "$cheshire" script verilator \
  -t rtl -t cva6 -t "$target" > "$build/sources-base.f"
axi_dir=$("$tools/bin/bender" -d "$cheshire" path axi)
idma_base=$("$tools/bin/bender" -d "$cheshire" path idma)
cva6_base=$("$tools/bin/bender" -d "$cheshire" path cva6)

python3 - "$build/sources-base.f" "$build/sources.f" \
    "$cheshire" "$cheshire_variant" "$idma_base" "$idma_variant" \
    "$cva6_base" "$cva6_variant" "$here" "$cell" <<'PY'
from pathlib import Path
import sys

(src, dst, cheshire, cheshire_variant, idma, idma_variant,
 cva6, cva6_variant, here, cell) = sys.argv[1:]
src, dst = Path(src), Path(dst)
cheshire, cheshire_variant = Path(cheshire), Path(cheshire_variant)
idma, idma_variant = Path(idma), Path(idma_variant)
cva6, cva6_variant, here = Path(cva6), Path(cva6_variant), Path(here)
text = src.read_text()
replacements = [
    (cheshire / "hw/cheshire_idma_wrap.sv",
     cheshire_variant / "hw/cheshire_idma_wrap.sv", 1),
    (cheshire / "hw/cheshire_pkg.sv",
     cheshire_variant / "hw/cheshire_pkg.sv", 1),
    (cheshire / "hw/cheshire_soc.sv",
     cheshire_variant / "hw/cheshire_soc.sv", 1),
    (idma, idma_variant, None),
    (cva6 / "core/cva6.sv", cva6_variant / "core/cva6.sv", 1),
]
if cell == "hpd":
    replacements.append((
        cva6 / "core/include/cv64a6_imafdchsclic_sv39_hpdcache_config_pkg.sv",
        here / "rtl-overrides/cv64a6_imafdchsclic_sv39_hpdcache_config_pkg.sv",
        1))
for old, new, exact in replacements:
    count = text.count(str(old))
    if exact is not None and count != exact:
        raise SystemExit(f"expected {exact} occurrence(s) of {old}, got {count}")
    if exact is None and count == 0:
        raise SystemExit(f"source-list path absent: {old}")
    text = text.replace(str(old), str(new))
dst.write_text(text)
PY

set +e
/usr/bin/time -v "$tools/verilator-5.052/bin/verilator" \
  --binary --assert --timing --timescale 1ns/1ps \
  -Wno-fatal --error-limit 1000 "${define[@]}" \
  -f "$build/sources.f" "$axi_dir/src/axi_sim_mem.sv" \
  "$here/rtl/tb_cheshire_linux_dma_cache.sv" \
  --top-module tb_cheshire_linux_dma_cache \
  --Mdir "$build/obj_dir" -o ../simv \
  --build-jobs "${BUILD_JOBS:-4}" > "$build/build.log" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > "$build/build.exit"
[[ $rc -eq 0 ]] || exit "$rc"
sha256sum "$build/simv" "$build/sources.f" > "$build/SHA256SUMS.sim"
printf 'Built %s\n' "$build/simv"

