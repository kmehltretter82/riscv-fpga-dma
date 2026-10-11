#!/usr/bin/env python3
"""Bounded self-tests for the DMA regression runner and verifier."""

from __future__ import annotations

import concurrent.futures
import hashlib
import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

import run as runner


ROOT = Path(__file__).resolve().parent
RUNNER = ROOT / "run.py"
VERIFIER = ROOT / "verify.py"


def invoke(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def reseal(root: Path) -> None:
    sums = root / "SHA256SUMS"
    files = sorted(path for path in root.rglob("*")
                   if path.is_file() and path != sums)
    sums.write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  "
        f"{path.relative_to(root).as_posix()}\n"
        for path in files
    ))


def write_manifest(base: Path, phase: str, script: Path,
                   watched: Path) -> Path:
    manifest = {
        "schema_version": 1,
        "name": "DMA regression harness self-test",
        "default_tier": "control",
        "tiers": {"control": [phase]},
        "phases": {
            phase: {
                "status": "ready",
                "description": "bounded harness self-test",
                "timeout_seconds": 10,
                "cwd": str(base),
                "argv": ["{python}", str(script)],
                "requires": [
                    {"path": str(script), "kind": "file",
                     "nonempty": True},
                    {"path": str(watched), "kind": "file",
                     "nonempty": True},
                ],
                "revision_roots": [],
                "gates": {
                    "allowed_exit_codes": [0],
                    "require": [
                        {"pattern": "(?m)^SELFTEST-PASS$", "exact": 1}
                    ],
                    "forbid": ["SELFTEST-FAIL"],
                },
            }
        },
    }
    path = base / f"{phase}.manifest.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return path


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        ids = list(pool.map(lambda _: runner.default_run_id(), range(128)))
    require(len(ids) == len(set(ids)), "concurrent run IDs collided")
    require(all(runner.SAFE_RUN_ID.fullmatch(value) for value in ids),
            "a generated run ID is unsafe")

    with tempfile.TemporaryDirectory(prefix="dma-regression-selftest-",
                                     dir="/tmp") as temporary:
        base = Path(temporary)
        output = base / "runs"
        watched = base / "watched.input"
        watched.write_text("stable\n")
        pass_script = base / "pass.py"
        pass_script.write_text('print("SELFTEST-PASS")\n')
        manifest = write_manifest(base, "selftest-pass", pass_script, watched)

        completed = invoke([
            str(RUNNER), "--quiet", "--manifest", str(manifest),
            "--output-root", str(output), "--run-id", "accepted",
        ])
        require(completed.returncode == 0,
                f"accepted control failed:\n{completed.stdout}{completed.stderr}")
        accepted = output / "accepted"
        verified = invoke([str(VERIFIER), str(accepted)])
        require(verified.returncode == 0,
                f"accepted bundle did not verify:\n{verified.stdout}{verified.stderr}")
        audited = invoke([str(accepted / "audit-inputs.py"), str(accepted)])
        require(audited.returncode == 0,
                f"accepted bundle inputs did not audit:\n"
                f"{audited.stdout}{audited.stderr}")

        semantic = output / "semantic-tamper"
        shutil.copytree(accepted, semantic)
        with (semantic / "selftest-pass" / "process.log").open("a") as handle:
            handle.write("SELFTEST-PASS\n")
        reseal(semantic)
        rejected = invoke([str(VERIFIER), str(semantic)])
        require(rejected.returncode != 0 and
                "recorded gates differ from replayed gates" in rejected.stderr,
                "checksum-consistent semantic tamper was accepted")

        manifest_tamper = output / "manifest-tamper"
        shutil.copytree(accepted, manifest_tamper)
        record_path = manifest_tamper / "run.json"
        record = json.loads(record_path.read_text())
        record["manifest_sha256"] = "0" * 64
        record_path.write_text(json.dumps(record, indent=2,
                                          sort_keys=True) + "\n")
        reseal(manifest_tamper)
        rejected = invoke([str(VERIFIER), str(manifest_tamper)])
        require(rejected.returncode != 0 and
                "manifest_sha256 does not match" in rejected.stderr,
                "checksum-consistent manifest tamper was accepted")

        watched.write_text("before\n")
        slow_script = base / "slow.py"
        slow_script.write_text(
            'import time\ntime.sleep(1.5)\nprint("SELFTEST-PASS")\n'
        )
        race_manifest = write_manifest(base, "selftest-race", slow_script,
                                       watched)
        process = subprocess.Popen([
            str(RUNNER), "--quiet", "--manifest", str(race_manifest),
            "--output-root", str(output), "--run-id", "input-race",
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        time.sleep(0.5)
        watched.write_text("after\n")
        race_output, _ = process.communicate(timeout=20)
        require(process.returncode == 1,
                f"input race did not fail:\n{race_output}")
        race_record = json.loads((output / "input-race" / "run.json").read_text())
        require(race_record.get("status") == "failed" and
                "prerequisite hashes or metadata changed after preflight" in
                race_record.get("orchestrator_error", ""),
                "input race lacked the expected sealed failure")
        verified = invoke([
            str(VERIFIER), "--integrity-only", str(output / "input-race")
        ])
        require(verified.returncode == 0,
                f"failed input-race evidence is invalid:\n"
                f"{verified.stdout}{verified.stderr}")

    print("PASS: 128 unique IDs; accepted bundle and input audit; semantic "
          "and manifest tamper rejection; changed-during-run input rejection")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
