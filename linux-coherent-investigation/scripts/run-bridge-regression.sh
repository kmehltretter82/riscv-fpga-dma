#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
verilator="$workspace/.tools/verilator-5.052/bin/verilator"
build="$here/build/bridge-regression"
log="$here/out/bridge-regression.log"

rm -rf -- "$build"
mkdir -p -- "$build" "$here/out"
"$verilator" --binary --assert --timing -Wall -Wno-fatal \
  --top-module tb_coherence_bridge \
  "$here/rtl/phase11_wt_coherence_bridge.sv" \
  "$here/rtl/tb_coherence_bridge.sv" \
  --Mdir "$build/obj_dir" -o ../simv --build-jobs "${BUILD_JOBS:-2}" \
  > "$build/build.log" 2>&1
"$build/simv" > "$log" 2>&1
grep -Fq 'PHASE11-COHERENCE-BRIDGE-PASS' "$log"
[[ $(grep -Fc 'COHERENCE_RECORD run=' "$log") -eq 3 ]]
if grep -Eq '%Error|Assertion failed|\$fatal' "$log"; then
  printf 'failure signature in bridge regression\n' >&2
  exit 1
fi
printf 'PASS: coherent bridge positive and two negative controls\n'
sha256sum "$here/rtl/phase11_wt_coherence_bridge.sv" \
  "$here/rtl/tb_coherence_bridge.sv" "$build/simv" "$log" \
  > "$here/out/SHA256SUMS.bridge"
