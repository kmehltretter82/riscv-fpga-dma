#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
sim="$here/build/sim-coherent/simv"
memh=${MEMH:-$here/out/fw_payload-coherent.memh}
log="$here/out/coherent-bound-100.log"
exit_file="$here/out/coherent-bound-100.exit"

[[ -x $sim ]] || { printf 'missing simulator: %s\n' "$sim" >&2; exit 2; }
[[ -s $memh ]] || {
  # Elaboration/control does not fetch memory before the 100-cycle bound; a
  # one-word image keeps the test explicit without pretending to be Linux.
  memh="$here/out/bound-placeholder.memh"
  printf '00000000\n' > "$memh"
}
rm -f -- "$exit_file"
set +e
"$sim" "+MEMH=$memh" +MAX_CYCLES=100 +NO_DASM_TRACE > "$log" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" > "$exit_file"
if [[ $rc -eq 0 ]]; then
  printf '100-cycle control unexpectedly passed\n' >&2
  exit 1
fi
grep -Fq 'timeout after 100 cycles jobs=0/0' "$log"
if grep -Fq 'FPGA-LINUX-DMA-CACHE-PASS' "$log"; then
  printf 'false Linux pass token in bounded control\n' >&2
  exit 1
fi
printf 'PASS: coherent model rejects the 100-cycle internal bound (rc=%s)\n' "$rc"
sha256sum "$log" "$exit_file" "$memh" > "$here/out/SHA256SUMS.bound"
