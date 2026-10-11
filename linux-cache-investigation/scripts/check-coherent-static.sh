#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
verilator="$workspace/.tools/verilator-5.052/bin/verilator"
rtl="$here/rtl/coherent"
build="$here/build/coherent-static"

rm -rf -- "$build"
mkdir -p -- "$build"
"$verilator" --lint-only --timing -Wall -Wno-fatal \
  --top-module tb_bridge_static \
  "$rtl/phase11_wt_dma_inval_if.sv" \
  "$rtl/phase11_idma_wt_write_bridge.sv" \
  "$rtl/tb_bridge_static.sv" > "$build/positive.log" 2>&1

set +e
"$verilator" --lint-only --timing -Wall -Wno-fatal \
  --top-module tb_bridge_bad_cache_type \
  "$rtl/phase11_idma_wt_write_bridge.sv" \
  "$rtl/tb_bridge_static.sv" > "$build/non-wt-negative.log" 2>&1
negative_rc=$?
set -e
if [[ $negative_rc -eq 0 ]]; then
  printf 'non-WT coherent bridge elaborated unexpectedly\n' >&2
  exit 1
fi
grep -Fq 'phase11_bridge_requires_wt_cache' "$build/non-wt-negative.log"
printf '0\n' > "$build/positive.exit"
printf '%s\n' "$negative_rc" > "$build/non-wt-negative.exit"
sha256sum "$rtl/phase11_wt_dma_inval_if.sv" \
  "$rtl/phase11_idma_wt_write_bridge.sv" \
  "$rtl/INTEGRATION.md" > "$build/SHA256SUMS.static"
printf 'PASS: WT bridge linted; non-WT elaboration rejected (rc=%s)\n' \
  "$negative_rc"
