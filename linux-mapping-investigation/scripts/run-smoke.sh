#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-}
seconds=${WALL_SECONDS:-7200}
cycles=${MAX_CYCLES:-250000000}
sim="$here/build/sim-mapping/simv"

case "$mode" in
	direct)
		memh="$here/out/fw_payload-direct.memh"
		marker=FPGA-LINUX-DMA-MAPPING-DIRECT-PASS
		expected_jobs=272
		expected_cache=814
		;;
	swiotlb)
		memh="$here/out/fw_payload-swiotlb.memh"
		marker=FPGA-LINUX-DMA-MAPPING-SWIOTLB-PASS
		expected_jobs=271
		expected_cache=811
		;;
	negative)
		memh="$here/out/fw_payload-negative.memh"
		marker=FPGA-LINUX-DMA-API-NEGATIVE-PASS
		expected_jobs=0
		expected_cache=0
		;;
	*)
		printf 'usage: %s {direct|swiotlb|negative}\n' "$0" >&2
		exit 2
		;;
esac
log="$here/out/verilator-linux-mapping-$mode.log"
exit_file="$here/out/verilator-linux-mapping-$mode.exit"
rm -f -- "$exit_file"

[[ -x $sim ]] || {
	printf 'Missing mapping simulator: run scripts/build-sim.sh\n' >&2
	exit 2
}
[[ -s $memh ]] || {
	printf 'Missing %s payload: run scripts/build-software.sh\n' "$mode" >&2
	exit 2
}
sha256sum -c "$here/out/SHA256SUMS.software"
sha256sum -c "$here/out/SHA256SUMS.simulator"

sim_args=("+MEMH=$memh" "+MAX_CYCLES=$cycles" +NO_DASM_TRACE)
if [[ $mode == negative ]]; then
	sim_args+=(+NEGATIVE)
fi
set +e
/usr/bin/time -v /usr/bin/timeout --signal=TERM --kill-after=10 \
	"$seconds" /usr/bin/stdbuf -oL -eL \
	"$sim" "${sim_args[@]}" \
	> "$log" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > "$exit_file"
cat "$log"

if [[ $rc -eq 0 ]]; then
	grep -q "$marker" "$log"
	if [[ $mode == negative ]]; then
		grep -q '^\[TB\] FPGA-LINUX-DMA-MAPPING-NEGATIVE-PASS ' "$log"
		grep -q '^\[TB\] iDMA jobs=0/0 busy=0 ar=0 aw=0 r=0 w=0 b=0$' "$log"
		awk '
			/^FPGA-LINUX-DMA-API-NEGATIVE: client / {
				for (i = 1; i <= NF; i++) {
					split($i, value, "=");
					if (value[1] == "pass") pass = value[2];
					if (value[1] == "rc") rc = value[2];
					if (value[1] == "cases") cases = value[2];
					if (value[1] == "cleanup") cleanup = value[2];
					if (value[1] == "errors") errors = value[2];
					if (value[1] == "free_before") before = value[2];
					if (value[1] == "free_after") after = value[2];
					if (value[1] == "cache_ops") cache = value[2];
				}
				if (pass == 1 && rc == 0 && cases == 5 && cleanup == 5 &&
				    errors == 5 && before == after && cache > 0)
					ok = 1;
			}
			END { exit !ok }
		' "$log"
		minimum=1
	else
		grep -q '^\[TB\] FPGA-LINUX-DMA-MAPPING-PASS ' "$log"
		grep -q "^\[TB\] iDMA jobs=$expected_jobs/$expected_jobs " "$log"
		grep -q " cache_ops=$expected_cache dma_api_errors=0$" "$log"
		minimum=$((expected_cache + 1))
	fi
	awk -v minimum="$minimum" '
		/^\[TB\] CVA6 D-cache flushes=/ {
			split($4, count, "="); split($5, ack, "=");
			if (count[2] + 0 >= minimum && count[2] == ack[2]) ok = 1;
		}
		END { exit !ok }
	' "$log"
elif [[ $rc -eq 124 ]]; then
	printf 'Bounded %s mapping smoke timed out after %s seconds; log: %s\n' \
		"$mode" "$seconds" "$log" >&2
	exit 124
else
	exit "$rc"
fi
