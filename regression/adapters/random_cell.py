#!/usr/bin/env python3
"""Run one prebuilt randomized Cheshire DMA cell without rebuilding sources."""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
from pathlib import Path


def checked_file(path: Path, executable: bool = False) -> Path:
    path = path.resolve()
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"missing or empty file: {path}")
    if executable and not path.stat().st_mode & 0o111:
        raise ValueError(f"file is not executable: {path}")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", required=True, type=Path)
    parser.add_argument("--memh", required=True, type=Path)
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--result-dir", required=True, type=Path)
    parser.add_argument("--seed", default="0x12345678")
    parser.add_argument("--count", type=int, default=16)
    parser.add_argument("--timing", choices=("direct", "fixed", "random"), default="random")
    parser.add_argument(
        "--scenario",
        choices=("clean", "reset", "read-error", "write-error"),
        default="clean",
    )
    parser.add_argument("--error-job", type=int, default=0)
    parser.add_argument("--error-burst", type=int, default=0)
    parser.add_argument("--timeout-cycles", type=int, default=84_000_000)
    args = parser.parse_args()
    if not 1 <= args.count <= 4096:
        parser.error("--count must be in 1..4096")
    if not 1 <= args.timeout_cycles <= 2_000_000_000:
        parser.error("--timeout-cycles must be in 1..2000000000")
    if not 0 <= args.error_job < args.count:
        parser.error("--error-job must identify a requested descriptor")
    if not 0 <= args.error_burst <= 65535:
        parser.error("--error-burst must be in 0..65535")

    try:
        sim = checked_file(args.sim, executable=True)
        memh = checked_file(args.memh)
        cases = checked_file(args.cases, executable=True)
        seed = int(args.seed, 0) & 0xFFFFFFFF
    except ValueError as exc:
        parser.error(str(exc))
    seed_hex = f"{seed:08x}"
    timing_seed = seed ^ 0x9E3779B9
    result_dir = args.result_dir.resolve()
    result_dir.mkdir(parents=True, exist_ok=False)
    summary = result_dir / "cases.json"
    table = result_dir / "cases.tsv"

    hash_process = subprocess.run(
        [
            str(cases),
            "--seed", f"0x{seed_hex}",
            "--count", str(args.count),
            "--profile", "full",
            "--hash-only",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    expected_hash = hash_process.stdout.strip().lower()
    if hash_process.returncode or len(expected_hash) != 8 or any(
        char not in "0123456789abcdef" for char in expected_hash
    ):
        print(
            f"case generator failed: rc={hash_process.returncode} "
            f"stdout={hash_process.stdout!r} stderr={hash_process.stderr!r}",
            file=sys.stderr,
        )
        return 2
    generate = subprocess.run(
        [
            str(cases),
            "--seed", f"0x{seed_hex}",
            "--count", str(args.count),
            "--profile", "full",
            "--tsv", str(table),
            "--summary", str(summary),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if generate.returncode:
        print(f"case generator failed: {generate.stderr}", file=sys.stderr)
        return 2

    command = [
        str(sim),
        f"+MEMH={memh}",
        f"+SEED={seed_hex}",
        f"+CASES={args.count}",
        "+SKIP_CASES=0",
        "+EXEC_MASK=00000000",
        f"+TIMING_SEED={timing_seed:08x}",
        f"+EXPECT_HASH={expected_hash}",
        f"+TIMEOUT_CYCLES={args.timeout_cycles}",
    ]
    if args.timing == "fixed":
        command.append("+AXI_FIXED")
    elif args.timing == "random":
        command.append("+AXI_RANDOM")
    if args.scenario == "reset":
        command.append("+DMA_RESET")
    elif args.scenario in {"read-error", "write-error"}:
        command.extend(
            [
                "+READ_ERROR" if args.scenario == "read-error" else "+WRITE_ERROR",
                f"+ERROR_JOB={args.error_job}",
                f"+ERROR_BURST={args.error_burst}",
            ]
        )

    (result_dir / "invocation.json").write_text(
        json.dumps(
            {
                "argv": command,
                "argv_shell_quoted_for_display_only": shlex.join(command),
                "seed": f"0x{seed_hex}",
                "timing_seed": f"0x{timing_seed:08x}",
                "descriptor_hash": f"0x{expected_hash}",
                "count": args.count,
                "timing": args.timing,
                "scenario": args.scenario,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    print(f"random-cell command: {shlex.join(command)}")
    process = subprocess.run(command, check=False)
    (result_dir / "sim.exit").write_text(f"{process.returncode}\n")
    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())

