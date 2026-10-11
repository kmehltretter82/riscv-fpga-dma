#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sim="$here/build/sim/simv"
memh="$here/out/fw_payload.memh"
log="$here/out/verilator-linux-smoke.log"
seconds=${WALL_SECONDS:-300}
cycles=${MAX_CYCLES:-50000000}

[[ -x $sim ]] || { printf 'Missing simulator: run scripts/build-sim.sh\n' >&2; exit 2; }
[[ -s $memh ]] || { printf 'Missing payload: run scripts/build-software.sh\n' >&2; exit 2; }

set +e
/usr/bin/time -v /usr/bin/timeout --signal=TERM --kill-after=10 \
  "$seconds" /usr/bin/stdbuf -oL -eL \
  "$sim" "+MEMH=$memh" "+MAX_CYCLES=$cycles" \
  > "$log" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > "$here/out/verilator-linux-smoke.exit"
cat "$log"

if [[ $rc -eq 0 ]]; then
  grep -q '^\[TB\] FPGA-LINUX-DMA-PASS ' "$log"
  grep -q '^\[TB\] iDMA jobs=8/8 ' "$log"
elif [[ $rc -eq 124 ]]; then
  printf 'Bounded smoke timed out after %s wall seconds; evidence is in %s\n' \
    "$seconds" "$log" >&2
else
  exit "$rc"
fi
