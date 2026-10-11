#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cell=${CELL:-}
case "$cell" in
  legacy|hpd) ;;
  *) printf 'CELL must be legacy or hpd\n' >&2; exit 2 ;;
esac

sim="$here/build/sim-$cell/simv"
memh="$here/out/fw_payload-$cell.memh"
log="$here/out/bounded-control-$cell.log"
exit_file="$here/out/bounded-control-$cell.exit"

[[ -x $sim ]] || { printf 'missing simulator: %s\n' "$sim" >&2; exit 2; }
[[ -s $memh ]] || { printf 'missing payload: %s\n' "$memh" >&2; exit 2; }
rm -f -- "$log" "$exit_file"

set +e
/usr/bin/timeout --signal=TERM --kill-after=10 60 \
  /usr/bin/stdbuf -oL -eL "$sim" "+MEMH=$memh" \
  +MAX_CYCLES=100 +NO_DASM_TRACE > "$log" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > "$exit_file"

if [[ $rc -eq 0 || $rc -eq 124 ]]; then
  printf 'control did not reach the internal fail-closed bound (rc=%s)\n' \
    "$rc" >&2
  exit 1
fi
grep -Fq 'timeout after 100 cycles jobs=0/0' "$log"
if grep -Fq 'FPGA-LINUX-DMA-CACHE-PASS' "$log"; then
  printf 'control emitted a false pass token\n' >&2
  exit 1
fi
printf 'PASS: %s 100-cycle cache control failed closed (native rc=%s)\n' \
  "$cell" "$rc"
