#!/usr/bin/env python3
"""Run and independently gate the focused iDMA error-drain matrix."""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
from pathlib import Path


def fail(message: str) -> int:
    print(f"adapter failure: {message}", file=sys.stderr)
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", required=True, type=Path)
    parser.add_argument("--memh", required=True, type=Path)
    parser.add_argument("--result-dir", required=True, type=Path)
    args = parser.parse_args()
    sim = args.sim.resolve()
    memh = args.memh.resolve()
    if not sim.is_file() or not sim.stat().st_mode & 0o111:
        parser.error(f"simulator is missing or not executable: {sim}")
    if not memh.is_file() or memh.stat().st_size == 0:
        parser.error(f"payload is missing or empty: {memh}")
    result_dir = args.result_dir.resolve()
    result_dir.mkdir(parents=True, exist_ok=False)

    completion_re = re.compile(r"completion: .* prefix=(\d+) rc=(\d+)")
    activity_re = re.compile(r"backend_rsp=(\d+) backend_err=(\d+)")
    ids_re = re.compile(r"IDs: done=(\d+) next=(\d+)")
    rows = []
    for stall in (0, 1):
        for channel in ("read", "write"):
            for burst in (0, 1, 2):
                stem = f"stall{stall}-{channel}-burst{burst}"
                command = [
                    str(sim),
                    f"+MEMH={memh}",
                    "+EXPECT_ABORT",
                    "+ALLOW_FULL_ABORT",
                    f"+ERROR_BURST={burst}",
                    "+READ_ERROR" if channel == "read" else "+WRITE_ERROR",
                ]
                if stall:
                    command.append("+AXI_STALLS")
                log_path = result_dir / f"{stem}.log"
                with log_path.open("w") as log:
                    process = subprocess.run(
                        command,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                        text=True,
                        check=False,
                    )
                (result_dir / f"{stem}.exit").write_text(f"{process.returncode}\n")
                text = log_path.read_text(errors="replace")
                expected = [
                    r"\[TB\] CVA6\+iDMA error-policy PASS",
                    r"\[TB\] DMA activity: jobs=2/2",
                    r"backend_rsp=3 backend_err=1",
                    r"\[TB\] IDs: done=3 next=4",
                    rf"injected one-shot {channel} SLVERR at burst={burst}",
                ]
                if process.returncode:
                    return fail(f"{stem} returned {process.returncode}; see {log_path}")
                for pattern in expected:
                    if len(re.findall(pattern, text)) != 1:
                        return fail(f"{stem} did not contain exactly one {pattern!r}")
                if "Verilog $stop" in text or "Assertion failed" in text:
                    return fail(f"{stem} contains an RTL failure marker")
                completion = completion_re.search(text)
                activity = activity_re.search(text)
                ids = ids_re.search(text)
                if not completion or not activity or not ids:
                    return fail(f"{stem} counters could not be parsed")
                if completion.group(2) != "0":
                    return fail(f"{stem} firmware rc is {completion.group(2)}")
                rows.append(
                    {
                        "stall": stall,
                        "channel": channel,
                        "burst": burst,
                        "returncode": process.returncode,
                        "prefix": int(completion.group(1)),
                        "backend_rsp": int(activity.group(1)),
                        "backend_err": int(activity.group(2)),
                        "done": int(ids.group(1)),
                        "next": int(ids.group(2)),
                    }
                )
                print(f"PASS {stem}")

    with (result_dir / "results.tsv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]), delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)
    (result_dir / "summary.json").write_text(
        json.dumps({"passed": len(rows), "expected": 12, "rows": rows}, indent=2) + "\n"
    )
    print("PASS: 12/12 read/write burst-position and latency cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

