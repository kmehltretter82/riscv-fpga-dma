#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sim="$here/build/sim-no-trace/simv"
memh="$here/out/fw_payload.memh"
log="$here/out/verilator-linux-smoke-no-trace.log"
exit_file="$here/out/verilator-linux-smoke-no-trace.exit"
seconds=${WALL_SECONDS:-7200}
cycles=${MAX_CYCLES:-200000000}

[[ -x $sim ]] || {
  printf 'Missing no-trace simulator: build/sim-no-trace/simv\n' >&2
  exit 2
}
[[ -s $memh ]] || {
  printf 'Missing payload: run scripts/build-software.sh\n' >&2
  exit 2
}
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

if [[ $rc -eq 0 ]]; then
  grep -q '^\[TB\] FPGA-LINUX-DMA-PASS ' "$log"
  grep -q '^\[TB\] iDMA jobs=8/8 ' "$log"
elif [[ $rc -eq 124 ]]; then
  printf 'Bounded no-trace smoke timed out after %s wall seconds; evidence is in %s\n' \
    "$seconds" "$log" >&2
  exit 124
else
  exit "$rc"
fi
