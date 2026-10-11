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


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


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

    try:
        record = json.loads(run_json.read_text())
        status = record["status"]
        for field, relative in (
            ("runner_sha256", "runner.py"),
            ("verifier_sha256", "verify.py"),
            ("adopter_sha256", "adopt.py"),
        ):
            if field in record:
                path = root / relative
                if not path.is_file() or sha256(path) != record[field]:
                    errors.append(f"{field} does not match {relative}")
    except (OSError, json.JSONDecodeError, KeyError) as exc:
        errors.append(f"invalid run.json: {exc}")
        status = "invalid"
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

