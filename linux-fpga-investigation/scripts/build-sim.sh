#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(cd -- "$here/.." && pwd)
cheshire="$workspace/cheshire"
tools="$workspace/.tools"
build="$here/build/sim"

expected_cheshire=292d2c091ffed3e194b0f437b5b3460813905e26
actual_cheshire=$(git -C "$cheshire" rev-parse HEAD)
if [[ $actual_cheshire != "$expected_cheshire" ]]; then
  printf 'Cheshire revision mismatch: expected %s, got %s\n' \
    "$expected_cheshire" "$actual_cheshire" >&2
  exit 2
fi

export BENDER_DB_DIR="$workspace/.cache/bender-db"
export BENDER_LOCAL=true

mkdir -p -- "$build"
"$tools/bin/bender" -d "$cheshire" script verilator \
  -t rtl -t cva6 -t cv64a6_imafdchsclic_sv39_wb > "$build/sources.f"
axi_dir=$("$tools/bin/bender" -d "$cheshire" path axi)

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
