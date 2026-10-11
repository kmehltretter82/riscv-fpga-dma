#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOG="$ROOT/logs/arch-tests-run.log"
CLEAN_LOG="$ROOT/logs/arch-tests-run.clean.log"
EXIT_FILE="$ROOT/logs/arch-tests-run.exit"

test -s "$LOG"
test -s "$CLEAN_LOG"
test -s "$EXIT_FILE"

rc=$(cat "$EXIT_FILE")
if [[ $rc != 0 ]]; then
    printf 'Architectural-test simulator exit was %s, expected 0\n' "$rc" >&2
    exit 2
fi

summary=$(grep -Eo 'Summary: passed [0-9]+ of [0-9]+' "$CLEAN_LOG" |
    tail -1 || true)
if [[ $summary != 'Summary: passed 38 of 38' ]]; then
    printf 'Missing exact 38/38 supported architectural-test summary: %s\n' \
        "${summary:-missing}" >&2
    exit 2
fi

grep -q 'You can close the test!' "$CLEAN_LOG"
grep -q ' completed after ' "$CLEAN_LOG"
if grep -Eq 'Summary: failed|ERROR:|timed out after|\*\*\* FAILED \*\*\*' \
        "$CLEAN_LOG"; then
    printf 'Failure marker found in architectural-test output\n' >&2
    exit 2
fi

printf 'Supported architectural IOMMU tests passed: %s\n' "$summary"
