#!/usr/bin/env python3
"""Recheck a regression bundle's live prerequisites without modifying it."""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

try:
    import run as runner
except ModuleNotFoundError:  # copied evidence bundles name it runner.py
    import runner  # type: ignore[no-redef]


def load_json(path: Path, label: str) -> object:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise runner.RegressionError(f"cannot read {label} {path}: {exc}") from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--phase", action="append", default=[])
    parser.add_argument(
        "--output",
        type=Path,
        help="write the audit JSON outside the sealed run directory",
    )
    return parser.parse_args()


def capture_prerequisite(before: object) -> tuple[dict[str, object], list[str]]:
    if not isinstance(before, dict):
        return {}, ["recorded prerequisite is not an object"]
    if isinstance(before.get("command"), str):
        command = before["command"]
        located = shutil.which(command)
        if located is None:
            return {"command": command, "available": False}, [
                f"required command is missing: {command}"
            ]
        path = Path(located).resolve()
        stat = path.stat()
        return {
            "command": command,
            "available": True,
            "path": str(path),
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
            "sha256": runner.sha256(path),
        }, []
    if not isinstance(before.get("path"), str):
        return {}, ["recorded prerequisite has neither command nor path"]
    path = Path(before["path"])
    if not path.exists():
        return {"path": str(path), "available": False, "problem": "missing"}, [
            f"required path is missing: {path}"
        ]
    kind = "directory" if path.is_dir() else "file"
    item: dict[str, object] = {
        "path": str(path),
        "resolved_path": str(path.resolve()),
        "available": True,
        "kind": kind,
        "size": path.stat().st_size,
        "mtime_ns": path.stat().st_mtime_ns,
    }
    if path.is_file():
        item["sha256"] = runner.sha256(path)
    errors: list[str] = []
    if before.get("kind") not in (None, kind):
        errors.append(f"required path changed kind: {path}")
    if before.get("available") is not True:
        errors.append(f"recorded prerequisite was unavailable: {path}")
    return item, errors


def main() -> int:
    args = parse_args()
    root = args.run_dir.resolve()
    if not root.is_dir():
        raise runner.RegressionError(f"run directory is missing: {root}")
    manifest_path = root / "manifest.snapshot.json"
    preflight_path = root / "preflight.json"
    run_path = root / "run.json"
    runner.load_manifest(manifest_path)
    preflight = load_json(preflight_path, "preflight record")
    run_record = load_json(run_path, "run record")
    if not isinstance(preflight, dict) or not isinstance(run_record, dict):
        raise runner.RegressionError("preflight.json and run.json must be objects")
    phase_records = preflight.get("phases")
    if not isinstance(phase_records, list):
        raise runner.RegressionError("preflight.json has no phase list")
    recorded = {
        item.get("phase"): item
        for item in phase_records
        if isinstance(item, dict) and isinstance(item.get("phase"), str)
    }
    selected = args.phase or list(run_record.get("selected", []))
    if not selected or not all(isinstance(item, str) for item in selected):
        raise runner.RegressionError("no valid phase selection")
    unknown = [phase for phase in selected if phase not in recorded]
    if unknown:
        raise runner.RegressionError(
            f"phases are absent from preflight.json: {', '.join(unknown)}"
        )

    results: list[dict[str, object]] = []
    all_match = True
    for phase_id in selected:
        before = recorded[phase_id]
        before_prerequisites = before.get("prerequisites")
        before_revisions = before.get("revisions")
        if not isinstance(before_prerequisites, list) or not isinstance(
            before_revisions, list
        ):
            raise runner.RegressionError(
                f"malformed preflight evidence for phase: {phase_id}"
            )
        errors: list[str] = []
        prerequisites = []
        for prerequisite in before_prerequisites:
            current, current_errors = capture_prerequisite(prerequisite)
            prerequisites.append(current)
            errors.extend(current_errors)
        revision_paths = [
            item.get("path") for item in before_revisions if isinstance(item, dict)
        ]
        if len(revision_paths) != len(before_revisions) or not all(
            isinstance(path, str) for path in revision_paths
        ):
            raise runner.RegressionError(
                f"malformed revision evidence for phase: {phase_id}"
            )
        revisions = runner.capture_revisions(revision_paths) if not errors else []
        prerequisites_match = prerequisites == before_prerequisites
        revisions_match = revisions == before_revisions
        passed = not errors and prerequisites_match and revisions_match
        all_match &= passed
        results.append(
            {
                "phase": phase_id,
                "passed": passed,
                "prerequisites_match": prerequisites_match,
                "revisions_match": revisions_match,
                "errors": errors,
                "current_prerequisites": prerequisites,
                "current_revisions": revisions,
            }
        )

    audit = {
        "schema_version": 1,
        "captured_at": runner.utc_now(),
        "run_dir": str(root),
        "run_json_sha256": runner.sha256(run_path),
        "manifest_snapshot_sha256": runner.sha256(manifest_path),
        "preflight_sha256": runner.sha256(preflight_path),
        "selected": selected,
        "passed": all_match,
        "results": results,
    }
    rendered = json.dumps(audit, indent=2, sort_keys=True) + "\n"
    if args.output:
        destination = args.output.resolve()
        try:
            destination.relative_to(root)
        except ValueError:
            pass
        else:
            raise runner.RegressionError(
                "refusing to write inside the regression run directory"
            )
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".tmp")
        temporary.write_text(rendered)
        temporary.replace(destination)
    else:
        sys.stdout.write(rendered)
    print(
        f"{'PASS' if all_match else 'FAIL'}: {len(results)} phase input audit",
        file=sys.stderr,
    )
    return 0 if all_match else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except runner.RegressionError as exc:
        print(f"input audit error: {exc}", file=sys.stderr)
        raise SystemExit(2)
