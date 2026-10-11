#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE=$(cd "$ROOT/.." && pwd)
SRC="$WORKSPACE/sources/cva6-iommu"
FESVR="$ROOT/tools/fesvr"
VERILATOR="$WORKSPACE/.tools/verilator-5.052/bin/verilator"
PATCH="$ROOT/patches/cva6-iommu-verilator-5-compat.patch"
LOG="$ROOT/logs/cva6-verilator-build.log"
EXIT="$ROOT/logs/cva6-verilator-build.exit"
jobs=${BUILD_JOBS:-4}

expected=3009f0641dcf96e5003bc8f63babbdeec69b013b
actual=$(git -C "$SRC" rev-parse HEAD)
if [[ $actual != "$expected" ]]; then
    printf 'CVA6-IOMMU revision mismatch: expected %s, got %s\n' \
        "$expected" "$actual" >&2
    exit 2
fi
git -C "$SRC" diff --check
git -C "$SRC" apply --check --reverse "$PATCH"
test -s "$FESVR/lib/libfesvr.a"
test -x "$VERILATOR"

export RISCV="$FESVR"
export SPIKE_ROOT="$FESVR"

cd "$SRC"
rm -rf work-ver
set +e
MALLOC_ARENA_MAX=2 /usr/bin/time -v make -j1 verilate \
    NUM_JOBS="$jobs" \
    defines=WT_DCACHE \
    VERILATOR_OPT=-O0 \
    VERILATOR_EXTRA_ARGS="--verilate-jobs 1 --unroll-count 64 --output-split 20000 --output-split-cfuncs 500" \
    verilator="$VERILATOR" \
    2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
printf '%s\n' "$rc" >"$EXIT"
if [[ $rc -ne 0 ]]; then
    exit "$rc"
fi

model="$SRC/work-ver/Variane_testharness"
test -x "$model"
if grep -Fq '+define+WT_DCACHE+RVFI_TRACE' "$LOG"; then
    printf 'RVFI_TRACE unexpectedly remained enabled\n' >&2
    exit 2
fi
if grep -Fq "Bit [11] of signal 'ariane_testharness.i_ariane_peripherals.irq_sources'" "$LOG"; then
    printf 'IOMMU WSI source 11 is still multiply driven\n' >&2
    exit 2
fi
sha256sum "$model" >"$ROOT/logs/cva6-verilator-model.sha256"
printf 'CVA6-IOMMU Verilator model ready: %s\n' "$model"
