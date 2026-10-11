#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKSPACE=$(cd "$ROOT/.." && pwd)
SIM="$WORKSPACE/sources/cva6-iommu/work-ver/Variane_testharness"
ELF="$WORKSPACE/sources/riscv-iommu-tests/build/cva6/rv_iommu_test.elf"
LOG="$ROOT/logs/arch-tests-bound-control.log"
EXIT_FILE="$ROOT/logs/arch-tests-bound-control.exit"

test -x "$SIM"
test -s "$ELF"

set +e
/usr/bin/timeout --signal=TERM --kill-after=10 60 \
    "$SIM" --max-cycles=100 "$ELF" >"$LOG" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" >"$EXIT_FILE"
cat "$LOG"

if [[ $rc -ne 124 ]]; then
    printf 'Expected internal 100-cycle bound to return 124, got %d\n' "$rc" >&2
    exit 2
fi
grep -Fq "$ELF timed out after 100 cycles" "$LOG"
if grep -Eq 'Summary: passed| completed after ' "$LOG"; then
    printf 'Bound control contains a false completion marker\n' >&2
    exit 2
fi
printf 'Internal simulator bound control passed\n'
