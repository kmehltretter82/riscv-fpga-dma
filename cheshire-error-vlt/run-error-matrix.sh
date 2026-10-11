#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
build_dir="$script_dir/build-autoabort-drain"
sim="$build_dir/simv"
memh="$script_dir/fw/dma_error_test.memh"
out_dir="$build_dir/error-burst-matrix"

if [[ ! -x $sim ]]; then
  echo "missing $sim; run ./run.sh autoabort-drain first" >&2
  exit 2
fi

mkdir -p -- "$out_dir"
printf 'stall\tchannel\tburst\trc\tprefix\tbackend_rsp\tbackend_err\tdone\tnext\n' \
  > "$out_dir/results.tsv"

for stall in 0 1; do
  for channel in read write; do
    for burst in 0 1 2; do
      stem="stall${stall}-${channel}-burst${burst}"
      args=(
        "+MEMH=$memh"
        +EXPECT_ABORT
        +ALLOW_FULL_ABORT
        "+ERROR_BURST=$burst"
      )
      if [[ $channel == read ]]; then
        args+=(+READ_ERROR)
      else
        args+=(+WRITE_ERROR)
      fi
      if [[ $stall == 1 ]]; then
        args+=(+AXI_STALLS)
      fi

      set +e
      /usr/bin/time -v "$sim" "${args[@]}" > "$out_dir/$stem.log" 2>&1
      rc=$?
      set -e
      printf '%s\n' "$rc" > "$out_dir/$stem.exit"

      grep -q '\[TB\] CVA6+iDMA error-policy PASS' "$out_dir/$stem.log"
      grep -q '\[TB\] DMA activity: jobs=2/2' "$out_dir/$stem.log"
      grep -q 'backend_rsp=3 backend_err=1' "$out_dir/$stem.log"
      grep -q '\[TB\] IDs: done=3 next=4' "$out_dir/$stem.log"
      grep -q "injected one-shot $channel SLVERR at burst=$burst" \
        "$out_dir/$stem.log"
      [[ $rc -eq 0 ]]

      python3 - "$stall" "$channel" "$burst" "$rc" \
          "$out_dir/$stem.log" >> "$out_dir/results.tsv" <<'PY'
import re
import sys
from pathlib import Path

stall, channel, burst, rc, path = sys.argv[1:]
text = Path(path).read_text()
completion = re.search(r"completion: .* prefix=(\d+) rc=(\d+)", text)
activity = re.search(r"backend_rsp=(\d+) backend_err=(\d+)", text)
ids = re.search(r"IDs: done=(\d+) next=(\d+)", text)
if not completion or not activity or not ids:
    raise SystemExit(f"cannot parse {path}")
if completion.group(2) != "0":
    raise SystemExit(f"firmware failed in {path}")
print("\t".join((stall, channel, burst, rc, completion.group(1),
                 activity.group(1), activity.group(2),
                 ids.group(1), ids.group(2))))
PY
      printf 'PASS %s\n' "$stem"
    done
  done
done

echo "PASS: 12/12 read/write burst-position and latency cases"
