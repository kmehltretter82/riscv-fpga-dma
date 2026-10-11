#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE=$(cd "$ROOT/.." && pwd)
SRC="$WORKSPACE/sources/cva6-iommu"
TESTS="$WORKSPACE/sources/riscv-iommu-tests"
SIM="$SRC/work-ver/Variane_testharness"
ELF="$TESTS/build/cva6/rv_iommu_test.elf"
LOG="$ROOT/logs/arch-tests-run.log"
CLEAN_LOG="$ROOT/logs/arch-tests-run.clean.log"
EXIT_FILE="$ROOT/logs/arch-tests-run.exit"
WALL_SECONDS=${WALL_SECONDS:-3600}
MAX_CYCLES=${MAX_CYCLES:-20000000}

test -x "$SIM"
test -s "$ELF"

set +e
/usr/bin/time -v /usr/bin/timeout --signal=TERM --kill-after=10 \
    "$WALL_SECONDS" /usr/bin/stdbuf -oL -eL \
    "$SIM" --max-cycles="$MAX_CYCLES" --cycle-count "$ELF" \
    >"$LOG" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" >"$EXIT_FILE"

# Keep raw output and a deterministic text view without terminal color codes.
sed $'s/\033\\[[0-9;]*m//g' "$LOG" >"$CLEAN_LOG"
cat "$LOG"

if [[ $rc -ne 0 ]]; then
    exit "$rc"
fi
"$ROOT/scripts/validate-arch-tests-log.sh"
