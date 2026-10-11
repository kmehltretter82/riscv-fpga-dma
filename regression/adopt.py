#!/usr/bin/env python3
"""Seal a completed direct simulator run under the regression contract."""

from __future__ import annotations

import argparse
import json
import os
import shutil
from pathlib import Path

import run as runner


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", required=True)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--exit-file", required=True, type=Path)
    parser.add_argument("--source-command", required=True)
    parser.add_argument(
        "--interrupted",
        action="store_true",
        help="record that the completed source command was interrupted",
    )
    parser.add_argument("--manifest", type=Path, default=runner.DEFAULT_MANIFEST)
    parser.add_argument("--output-root", type=Path, default=runner.DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--run-id")
    args = parser.parse_args()
    if args.run_id and not runner.SAFE_RUN_ID.fullmatch(args.run_id):
        parser.error("--run-id must match [A-Za-z0-9][A-Za-z0-9_.-]{0,95}")
    return args


def stable_copy(source: Path, destination: Path) -> dict[str, object]:
    source = source.resolve()
    if not source.is_file() or source.is_symlink():
        raise runner.RegressionError(f"source is not a regular file: {source}")
    before = source.stat()
    before_hash = runner.sha256(source)
    shutil.copy2(source, destination)
    after = source.stat()
    after_hash = runner.sha256(source)
    if (
        before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or before_hash != after_hash
        or runner.sha256(destination) != before_hash
    ):
        raise runner.RegressionError(f"source changed while being copied: {source}")
    return {
        "path": str(source),
        "size": before.st_size,
        "mtime_ns": before.st_mtime_ns,
        "sha256": before_hash,
    }


def main() -> int:
    args = parse_args()
    manifest_path = args.manifest.resolve()
    manifest = runner.load_manifest(manifest_path)
    if args.phase not in manifest["phases"]:
        raise runner.RegressionError(f"unknown phase: {args.phase}")

    run_id = args.run_id or runner.default_run_id()
    output_root = args.output_root.resolve()
    run_dir = output_root / run_id
    resolved, problems = runner.preflight(manifest, [args.phase], run_dir, None)
    if problems:
        raise runner.RegressionError("; ".join(problems))
    phase = resolved[0]
    if run_dir.exists():
        raise runner.RegressionError(f"refusing to reuse output directory: {run_dir}")

    exit_text = args.exit_file.resolve().read_text().strip()
    try:
        returncode = int(exit_text, 10)
    except ValueError as exc:
        raise runner.RegressionError(f"invalid native exit status: {exit_text!r}") from exc

    run_dir.mkdir(parents=True)
    phase_dir = run_dir / args.phase
    phase_dir.mkdir()
    shutil.copy2(Path(__file__).resolve(), run_dir / "adopt.py")
    shutil.copy2(runner.SCRIPT, run_dir / "runner.py")
    shutil.copy2(runner.REGRESSION_ROOT / "verify.py", run_dir / "verify.py")
    shutil.copy2(runner.INPUT_AUDITOR, run_dir / "audit-inputs.py")
    shutil.copy2(manifest_path, run_dir / "manifest.snapshot.json")
    runner.dump_json(run_dir / "host.json", runner.host_metadata())
    runner.dump_json(
        run_dir / "preflight.json",
        {
            "captured_at": runner.utc_now(),
            "selected": [args.phase],
            "phases": [
                {
                    "phase": args.phase,
                    "prerequisites": phase["prerequisite_evidence"],
                    "revisions": phase["revision_evidence"],
                }
            ],
        },
    )

    log_evidence = stable_copy(args.log, phase_dir / "process.log")
    exit_evidence = stable_copy(args.exit_file, phase_dir / "native.exit")
    runner.assert_inputs_unchanged(phase)
    timed_out = returncode == 124
    passed, gates = runner.evaluate_gates(
        phase["gates"], phase_dir / "process.log", returncode,
        timed_out or args.interrupted,
    )
    invocation = {
        "mode": "adopted_completed_direct_run",
        "adopted_at": runner.utc_now(),
        "source_command": args.source_command,
        "source_interrupted": args.interrupted,
        "declared_argv": phase["argv"],
        "cwd": phase["cwd"],
        "timeout_seconds": phase["timeout_seconds"],
        "source_log": log_evidence,
        "source_exit": exit_evidence,
    }
    runner.dump_json(phase_dir / "invocation.json", invocation)
    result = {
        "phase": args.phase,
        "started_at": None,
        "finished_at": None,
        "adopted_at": runner.utc_now(),
        "duration_seconds": None,
        "returncode": returncode,
        "timed_out": timed_out,
        "interrupted": args.interrupted,
        "status": "passed" if passed else "failed",
        "gates": gates,
        "process_log": "process.log",
        "provenance": "completed direct run; preflight captured at adoption",
    }
    runner.dump_json(phase_dir / "result.json", result)
    run_record = {
        "schema_version": 1,
        "run_id": run_id,
        "started_at": None,
        "finished_at": None,
        "adopted_at": runner.utc_now(),
        "status": result["status"],
        "manifest": str(manifest_path),
        "manifest_sha256": runner.sha256(manifest_path),
        "runner_sha256": runner.sha256(runner.SCRIPT),
        "verifier_sha256": runner.sha256(runner.REGRESSION_ROOT / "verify.py"),
        "auditor_sha256": runner.sha256(runner.INPUT_AUDITOR),
        "adopter_sha256": runner.sha256(Path(__file__).resolve()),
        "selected": [args.phase],
        "results": [result],
        "interrupted": args.interrupted,
        "provenance": "completed direct run; preflight captured at adoption",
    }
    runner.dump_json(run_dir / "run.json", run_record)
    count = runner.write_checksums(run_dir)
    print(f"Evidence: {run_dir}")
    print(f"Checksummed files: {count}")
    print(f"Overall status: {result['status']}")
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except runner.RegressionError as exc:
        print(f"adoption error: {exc}", file=os.sys.stderr)
        raise SystemExit(2)
