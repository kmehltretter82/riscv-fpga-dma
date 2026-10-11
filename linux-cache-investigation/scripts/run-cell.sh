#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cell=${CELL:-}
case "$cell" in
  legacy) cell_name=legacy-wb-noncoherent ;;
  hpd) cell_name=hpdcache-wb-noncoherent ;;
  *) printf 'CELL must be legacy or hpd\n' >&2; exit 2 ;;
esac
sim="$here/build/sim-$cell/simv"
memh="$here/out/fw_payload-$cell.memh"
log="$here/out/verilator-linux-cache-$cell.log"
exit_file="$here/out/verilator-linux-cache-$cell.exit"
seconds=${WALL_SECONDS:-7200}
cycles=${MAX_CYCLES:-200000000}

[[ -x $sim ]] || { printf 'missing simulator: %s\n' "$sim" >&2; exit 2; }
[[ -s $memh ]] || { printf 'missing payload: %s\n' "$memh" >&2; exit 2; }
"$here/scripts/check-source-contracts.sh" >/dev/null
rm -f -- "$exit_file"
set +e
/usr/bin/time -v /usr/bin/timeout --signal=TERM --kill-after=10 \
  "$seconds" /usr/bin/stdbuf -oL -eL \
  "$sim" "+MEMH=$memh" "+MAX_CYCLES=$cycles" +NO_DASM_TRACE \
  > "$log" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > "$exit_file"
cat "$log"
if [[ $rc -eq 124 ]]; then
  printf 'bounded Phase 11 %s run timed out\n' "$cell" >&2
  exit 124
fi
[[ $rc -eq 0 ]] || exit "$rc"
grep -Fq "[TB] FPGA-LINUX-DMA-CACHE-PASS cell=$cell_name" "$log"
grep -Fq '[TB] iDMA jobs=3/3 ' "$log"
[[ $(grep -Fc "[TB] PHASE11_RECORD cell=$cell_name" "$log") -eq 3 ]]
grep -Fq "PHASE11_LINUX_RECORD cell=$cell_name run=positive " "$log"
grep -Fq "PHASE11_LINUX_RECORD cell=$cell_name run=stale-source " "$log"
grep -Fq "PHASE11_LINUX_RECORD cell=$cell_name run=stale-destination " "$log"
if grep -Eq 'FPGA-LINUX-DMA-CACHE-FAIL|%Error|Assertion failed|\$fatal' "$log"; then
  printf 'failure signature in accepted Phase 11 log\n' >&2
  exit 1
fi
printf 'Phase 11 %s accepted: %s\n' "$cell" "$log"
