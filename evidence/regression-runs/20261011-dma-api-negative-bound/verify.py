#!/usr/bin/env python3
"""Verify a sealed regression directory and its recorded result status."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


LINE = re.compile(r"^([0-9a-f]{64})  ([^\n]+)$")
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(path: Path, label: str, errors: list[str]) -> object | None:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"invalid {label}: {exc}")
        return None


def evaluate_gates(
    gates: object, log_path: Path, result: dict[str, object], errors: list[str]
) -> tuple[bool, list[dict[str, object]]]:
    if not isinstance(gates, dict):
        errors.append(f"missing gate contract for {result.get('phase')!r}")
        return False, []
    allowed = gates.get("allowed_exit_codes")
    requirements = gates.get("require", [])
    forbidden = gates.get("forbid", [])
    if (
        not isinstance(allowed, list)
        or not all(isinstance(value, int) for value in allowed)
        or not isinstance(requirements, list)
        or not isinstance(forbidden, list)
    ):
        errors.append(f"malformed gate contract for {result.get('phase')!r}")
        return False, []
    try:
        text = ANSI_ESCAPE.sub("", log_path.read_text(errors="replace"))
    except OSError as exc:
        errors.append(f"cannot read process log {log_path}: {exc}")
        return False, []

    returncode = result.get("returncode")
    timed_out = bool(result.get("timed_out")) or bool(result.get("interrupted"))
    records: list[dict[str, object]] = []
    exit_ok = isinstance(returncode, int) and not timed_out and returncode in allowed
    records.append(
        {
            "gate": "exit_code",
            "passed": exit_ok,
            "actual": returncode,
            "allowed": allowed,
            "timed_out": timed_out,
        }
    )
    for requirement in requirements:
        if (
            not isinstance(requirement, dict)
            or not isinstance(requirement.get("pattern"), str)
            or not isinstance(requirement.get("exact"), int)
        ):
            errors.append(f"malformed required gate for {result.get('phase')!r}")
            continue
        pattern = requirement["pattern"]
        try:
            count = sum(1 for _ in re.finditer(pattern, text))
        except re.error as exc:
            errors.append(
                f"invalid required regex for {result.get('phase')!r}: {exc}"
            )
            continue
        records.append(
            {
                "gate": "required_regex",
                "pattern": pattern,
                "expected_exact": requirement["exact"],
                "actual": count,
                "passed": count == requirement["exact"],
            }
        )
    for pattern in forbidden:
        if not isinstance(pattern, str):
            errors.append(f"malformed forbidden gate for {result.get('phase')!r}")
            continue
        try:
            count = sum(1 for _ in re.finditer(pattern, text))
        except re.error as exc:
            errors.append(
                f"invalid forbidden regex for {result.get('phase')!r}: {exc}"
            )
            continue
        records.append(
            {
                "gate": "forbidden_regex",
                "pattern": pattern,
                "actual": count,
                "passed": count == 0,
            }
        )
    return bool(records) and all(bool(item.get("passed")) for item in records), records


def verify_semantics(root: Path, record: object, errors: list[str]) -> str:
    if not isinstance(record, dict):
        errors.append("run.json is not an object")
        return "invalid"
    status = record.get("status")
    if not isinstance(status, str):
        errors.append("run.json status is missing or invalid")
        status = "invalid"

    manifest_path = root / "manifest.snapshot.json"
    manifest = load_json(manifest_path, "manifest.snapshot.json", errors)
    if not isinstance(manifest, dict) or not isinstance(manifest.get("phases"), dict):
        errors.append("manifest snapshot has no phase table")
        return status
    recorded_manifest_hash = record.get("manifest_sha256")
    if (
        not isinstance(recorded_manifest_hash, str)
        or sha256(manifest_path) != recorded_manifest_hash
    ):
        errors.append("manifest_sha256 does not match manifest.snapshot.json")

    selected = record.get("selected")
    results = record.get("results")
    if (
        not isinstance(selected, list)
        or not selected
        or not all(isinstance(item, str) for item in selected)
        or len(selected) != len(set(selected))
    ):
        errors.append("run.json selected phase list is malformed")
        return status
    phases = manifest["phases"]
    unknown = [phase for phase in selected if phase not in phases]
    if unknown:
        errors.append(f"selected phases absent from manifest: {unknown}")
    if not isinstance(results, list):
        errors.append("run.json results is not a list")
        return status

    result_phases: list[str] = []
    all_results_pass = True
    for index, embedded in enumerate(results):
        if not isinstance(embedded, dict):
            errors.append(f"run.json result {index} is not an object")
            all_results_pass = False
            continue
        phase = embedded.get("phase")
        if not isinstance(phase, str):
            errors.append(f"run.json result {index} has no phase")
            all_results_pass = False
            continue
        result_phases.append(phase)
        if phase not in phases:
            errors.append(f"result phase absent from manifest: {phase}")
            all_results_pass = False
            continue
        phase_dir = root / phase
        result_path = phase_dir / "result.json"
        disk_result = load_json(result_path, f"{phase}/result.json", errors)
        if disk_result != embedded:
            errors.append(f"embedded result differs from {phase}/result.json")
        process_log = embedded.get("process_log")
        if (
            not isinstance(process_log, str)
            or Path(process_log).is_absolute()
            or ".." in Path(process_log).parts
        ):
            errors.append(f"unsafe process_log path for {phase}")
            all_results_pass = False
            continue
        log_path = phase_dir / process_log
        if not log_path.is_file() or log_path.is_symlink():
            errors.append(f"missing regular process log for {phase}: {process_log}")
            all_results_pass = False
            continue
        passed, gate_records = evaluate_gates(
            phases[phase].get("gates"), log_path, embedded, errors
        )
        if embedded.get("gates") != gate_records:
            errors.append(f"recorded gates differ from replayed gates for {phase}")
        expected_status = "passed" if passed else "failed"
        if embedded.get("status") != expected_status:
            errors.append(
                f"recorded phase status for {phase} is {embedded.get('status')!r}, "
                f"replayed status is {expected_status!r}"
            )
        all_results_pass &= passed and disk_result == embedded

    if len(result_phases) != len(set(result_phases)):
        errors.append("duplicate phases in run.json results")
    if result_phases != selected[: len(result_phases)]:
        errors.append("result phases are not the selected phase prefix")

    expected_overall = "passed" if (
        not bool(record.get("interrupted", False))
        and "orchestrator_error" not in record
        and len(results) == len(selected)
        and all_results_pass
    ) else "failed"
    if status != expected_overall:
        errors.append(
            f"recorded regression status is {status!r}, replayed status is "
            f"{expected_overall!r}"
        )
    return status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument(
        "--integrity-only",
        action="store_true",
        help="accept an intact bundle whose regression status is failed",
    )
    args = parser.parse_args()
    root = args.run_dir.resolve()
    sums = root / "SHA256SUMS"
    run_json = root / "run.json"
    if not root.is_dir() or not sums.is_file() or not run_json.is_file():
        print("missing run directory, SHA256SUMS, or run.json", file=sys.stderr)
        return 2

    expected: dict[str, str] = {}
    errors: list[str] = []
    for path in root.rglob("*"):
        if path.is_symlink():
            errors.append(f"unsealed symlink: {path.relative_to(root).as_posix()}")
    for number, line in enumerate(sums.read_text().splitlines(), 1):
        match = LINE.fullmatch(line)
        if not match:
            errors.append(f"malformed SHA256SUMS line {number}")
            continue
        digest, relative = match.groups()
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts or relative in expected:
            errors.append(f"unsafe or duplicate manifest path: {relative}")
            continue
        expected[relative] = digest

    actual = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and not path.is_symlink() and path != sums
    }
    for relative in sorted(actual - expected.keys()):
        errors.append(f"unlisted file: {relative}")
    for relative in sorted(expected.keys() - actual):
        errors.append(f"missing file: {relative}")
    for relative in sorted(actual & expected.keys()):
        digest = sha256(root / relative)
        if digest != expected[relative]:
            errors.append(f"checksum mismatch: {relative}")

    record = load_json(run_json, "run.json", errors)
    if isinstance(record, dict):
        for field, relative in (
            ("runner_sha256", "runner.py"),
            ("verifier_sha256", "verify.py"),
            ("adopter_sha256", "adopt.py"),
            ("auditor_sha256", "audit-inputs.py"),
        ):
            if field in record:
                path = root / relative
                if not path.is_file() or sha256(path) != record[field]:
                    errors.append(f"{field} does not match {relative}")
    status = verify_semantics(root, record, errors)
    if status != "passed" and not args.integrity_only:
        errors.append(f"regression status is {status!r}; use --integrity-only for failed evidence")

    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: {len(expected)} checksums; regression status={status}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

