#!/usr/bin/env python3
"""Fail-closed orchestrator for the CPU-hosted Cheshire DMA regressions."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any


class RegressionError(Exception):
    pass


SCRIPT = Path(__file__).resolve()
REGRESSION_ROOT = SCRIPT.parent
DMA_ROOT = REGRESSION_ROOT.parent
DEFAULT_MANIFEST = REGRESSION_ROOT / "manifest.json"
DEFAULT_OUTPUT_ROOT = REGRESSION_ROOT / "runs"
INPUT_AUDITOR = REGRESSION_ROOT / "audit-inputs.py"
SAFE_RUN_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$")
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def default_run_id() -> str:
    """Return a readable ID that stays unique across PID namespaces."""
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{stamp}-{os.getpid()}-{secrets.token_hex(4)}"


def dump_json(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise RegressionError(f"cannot read manifest {path}: {exc}") from exc
    validate_manifest(manifest)
    return manifest


def validate_manifest(manifest: dict[str, Any]) -> None:
    if manifest.get("schema_version") != 1:
        raise RegressionError("manifest schema_version must be 1")
    phases = manifest.get("phases")
    tiers = manifest.get("tiers")
    if not isinstance(phases, dict) or not phases:
        raise RegressionError("manifest phases must be a nonempty object")
    if not isinstance(tiers, dict) or not tiers:
        raise RegressionError("manifest tiers must be a nonempty object")
    if manifest.get("default_tier") not in tiers:
        raise RegressionError("default_tier does not name a declared tier")

    for phase_id, phase in phases.items():
        if not SAFE_RUN_ID.fullmatch(phase_id):
            raise RegressionError(f"invalid phase identifier: {phase_id!r}")
        if not isinstance(phase, dict):
            raise RegressionError(f"phase {phase_id} must be an object")
        status = phase.get("status")
        if status not in {"ready", "planned"}:
            raise RegressionError(f"phase {phase_id} has invalid status {status!r}")
        if not isinstance(phase.get("description"), str):
            raise RegressionError(f"phase {phase_id} lacks a description")
        if status == "planned":
            if not isinstance(phase.get("reason"), str):
                raise RegressionError(f"planned phase {phase_id} lacks a reason")
            continue
        timeout = phase.get("timeout_seconds")
        if not isinstance(timeout, int) or not 1 <= timeout <= 86400:
            raise RegressionError(f"phase {phase_id} has an invalid timeout")
        argv = phase.get("argv")
        if not isinstance(argv, list) or not argv or not all(
            isinstance(item, str) and item for item in argv
        ):
            raise RegressionError(f"phase {phase_id} argv must be nonempty strings")
        if not isinstance(phase.get("cwd"), str):
            raise RegressionError(f"phase {phase_id} lacks cwd")
        if not isinstance(phase.get("requires", []), list):
            raise RegressionError(f"phase {phase_id} requires must be a list")
        env = phase.get("env", {})
        if not isinstance(env, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in env.items()
        ):
            raise RegressionError(f"phase {phase_id} env must map strings to strings")
        gates = phase.get("gates")
        if not isinstance(gates, dict):
            raise RegressionError(f"phase {phase_id} lacks gates")
        exits = gates.get("allowed_exit_codes")
        if not isinstance(exits, list) or not exits or not all(
            isinstance(value, int) for value in exits
        ):
            raise RegressionError(f"phase {phase_id} has invalid exit-code gate")
        for requirement in gates.get("require", []):
            if (
                not isinstance(requirement, dict)
                or not isinstance(requirement.get("pattern"), str)
                or not isinstance(requirement.get("exact"), int)
                or requirement["exact"] < 0
            ):
                raise RegressionError(f"phase {phase_id} has invalid required gate")
            try:
                re.compile(requirement["pattern"])
            except re.error as exc:
                raise RegressionError(
                    f"phase {phase_id} has invalid regex {requirement['pattern']!r}: {exc}"
                ) from exc
        for pattern in gates.get("forbid", []):
            if not isinstance(pattern, str):
                raise RegressionError(f"phase {phase_id} has non-string forbidden gate")
            try:
                re.compile(pattern)
            except re.error as exc:
                raise RegressionError(
                    f"phase {phase_id} has invalid forbidden regex {pattern!r}: {exc}"
                ) from exc

    for tier, members in tiers.items():
        if not SAFE_RUN_ID.fullmatch(tier):
            raise RegressionError(f"invalid tier identifier: {tier!r}")
        if not isinstance(members, list) or not all(member in phases for member in members):
            raise RegressionError(f"tier {tier} contains an unknown phase")


def format_value(value: str, context: dict[str, str], label: str) -> str:
    try:
        return value.format_map(context)
    except (KeyError, ValueError) as exc:
        raise RegressionError(f"cannot expand {label}: {value!r}: {exc}") from exc


def phase_context(run_dir: Path, phase_id: str) -> dict[str, str]:
    return {
        "python": sys.executable,
        "regression_root": str(REGRESSION_ROOT),
        "dma_root": str(DMA_ROOT),
        "run_dir": str(run_dir),
        "phase_dir": str(run_dir / phase_id),
    }


def resolve_phase(
    phase_id: str,
    phase: dict[str, Any],
    run_dir: Path,
    timeout_override: int | None,
) -> dict[str, Any]:
    if phase["status"] != "ready":
        raise RegressionError(f"phase {phase_id} is planned: {phase['reason']}")
    context = phase_context(run_dir, phase_id)
    cwd = Path(format_value(phase["cwd"], context, f"{phase_id}.cwd")).resolve()
    argv = [
        format_value(value, context, f"{phase_id}.argv") for value in phase["argv"]
    ]
    env = {
        key: format_value(value, context, f"{phase_id}.env.{key}")
        for key, value in phase.get("env", {}).items()
    }
    requirements = []
    for index, item in enumerate(phase.get("requires", [])):
        if not isinstance(item, dict) or ("path" in item) == ("command" in item):
            raise RegressionError(
                f"{phase_id}.requires[{index}] must contain exactly one of path/command"
            )
        resolved = dict(item)
        if "path" in item:
            if not isinstance(item["path"], str):
                raise RegressionError(f"{phase_id}.requires[{index}].path is invalid")
            resolved["path"] = format_value(
                item["path"], context, f"{phase_id}.requires[{index}].path"
            )
        else:
            if not isinstance(item["command"], str):
                raise RegressionError(f"{phase_id}.requires[{index}].command is invalid")
        requirements.append(resolved)
    revisions = [
        format_value(value, context, f"{phase_id}.revision_roots")
        for value in phase.get("revision_roots", [])
    ]
    timeout = timeout_override or phase["timeout_seconds"]
    return {
        "id": phase_id,
        "description": phase["description"],
        "cwd": str(cwd),
        "argv": argv,
        "env": env,
        "requires": requirements,
        "revision_roots": revisions,
        "timeout_seconds": timeout,
        "gates": phase["gates"],
    }


def check_resolved(resolved: dict[str, Any]) -> tuple[list[str], list[dict[str, Any]]]:
    errors: list[str] = []
    evidence: list[dict[str, Any]] = []
    cwd = Path(resolved["cwd"])
    if not cwd.is_dir():
        errors.append(f"working directory is missing: {cwd}")

    for requirement in resolved["requires"]:
        if "command" in requirement:
            command = requirement["command"]
            located = shutil.which(command)
            if located is None:
                errors.append(f"required command is missing: {command}")
                evidence.append({"command": command, "available": False})
            else:
                located_path = Path(located).resolve()
                stat = located_path.stat()
                evidence.append(
                    {
                        "command": command,
                        "available": True,
                        "path": str(located_path),
                        "size": stat.st_size,
                        "mtime_ns": stat.st_mtime_ns,
                        "sha256": sha256(located_path),
                    }
                )
            continue

        path = Path(requirement["path"])
        kind = requirement.get("kind", "any")
        exists = path.exists()
        problem = None
        if not exists:
            problem = "missing"
        elif kind == "file" and not path.is_file():
            problem = "not a regular file"
        elif kind == "directory" and not path.is_dir():
            problem = "not a directory"
        elif requirement.get("executable") and not os.access(path, os.X_OK):
            problem = "not executable"
        elif requirement.get("nonempty") and path.is_file() and path.stat().st_size == 0:
            problem = "empty"
        if problem:
            errors.append(f"required path is {problem}: {path}")
            evidence.append({"path": str(path), "available": False, "problem": problem})
        else:
            item = {
                "path": str(path),
                "resolved_path": str(path.resolve()),
                "available": True,
                "kind": "directory" if path.is_dir() else "file",
                "size": path.stat().st_size,
                "mtime_ns": path.stat().st_mtime_ns,
            }
            if path.is_file():
                item["sha256"] = sha256(path)
            evidence.append(item)

    executable = resolved["argv"][0]
    if "/" in executable:
        executable_path = Path(executable)
        if not executable_path.is_absolute():
            executable_path = cwd / executable_path
        if not executable_path.is_file() or not os.access(executable_path, os.X_OK):
            errors.append(f"command executable is unavailable: {executable_path}")
    elif shutil.which(executable) is None:
        errors.append(f"command executable is unavailable in PATH: {executable}")

    for root_text in resolved["revision_roots"]:
        root = Path(root_text)
        if not root.is_dir():
            errors.append(f"revision root is missing: {root}")
    return errors, evidence


def git_output(
    git: str, root: Path, *args: str
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [git, "-C", str(root), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def capture_revisions(roots: list[str]) -> list[dict[str, Any]]:
    git = shutil.which("git")
    if git is None:
        raise RegressionError("git is required to capture source revisions")
    records = []
    for root_text in roots:
        root = Path(root_text)
        head = git_output(git, root, "rev-parse", "HEAD")
        status = git_output(
            git, root, "status", "--porcelain=v1", "--untracked-files=no"
        )
        diff = git_output(git, root, "diff", "--no-ext-diff", "--binary", "HEAD", "--")
        if head.returncode or status.returncode or diff.returncode:
            details = (head.stderr + status.stderr + diff.stderr).decode(errors="replace").strip()
            raise RegressionError(f"cannot record Git revision for {root}: {details}")
        status_text = status.stdout.decode(errors="replace")
        records.append(
            {
                "path": str(root),
                "resolved_path": str(root.resolve()),
                "head": head.stdout.decode().strip(),
                "dirty": bool(status_text),
                "tracked_status": status_text.splitlines(),
                "tracked_diff_sha256": hashlib.sha256(diff.stdout).hexdigest(),
            }
        )
    return records


def evaluate_gates(
    gates: dict[str, Any], log_path: Path, returncode: int, timed_out: bool
) -> tuple[bool, list[dict[str, Any]]]:
    # Keep process.log byte-for-byte readable while making result gates
    # independent of harmless terminal coloring from upstream tests.
    text = ANSI_ESCAPE.sub("", log_path.read_text(errors="replace"))
    results: list[dict[str, Any]] = []
    allowed = gates["allowed_exit_codes"]
    exit_ok = not timed_out and returncode in allowed
    results.append(
        {
            "gate": "exit_code",
            "passed": exit_ok,
            "actual": returncode,
            "allowed": allowed,
            "timed_out": timed_out,
        }
    )
    for requirement in gates.get("require", []):
        count = sum(1 for _ in re.finditer(requirement["pattern"], text))
        passed = count == requirement["exact"]
        results.append(
            {
                "gate": "required_regex",
                "pattern": requirement["pattern"],
                "expected_exact": requirement["exact"],
                "actual": count,
                "passed": passed,
            }
        )
    for pattern in gates.get("forbid", []):
        count = sum(1 for _ in re.finditer(pattern, text))
        results.append(
            {
                "gate": "forbidden_regex",
                "pattern": pattern,
                "actual": count,
                "passed": count == 0,
            }
        )
    return all(result["passed"] for result in results), results


def terminate_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_phase(resolved: dict[str, Any], phase_dir: Path, quiet: bool) -> dict[str, Any]:
    phase_dir.mkdir(parents=True, exist_ok=False)
    invocation = {
        "phase": resolved["id"],
        "description": resolved["description"],
        "started_at": utc_now(),
        "cwd": resolved["cwd"],
        "argv": resolved["argv"],
        "argv_shell_quoted_for_display_only": shlex.join(resolved["argv"]),
        "environment_overrides": resolved["env"],
        "timeout_seconds": resolved["timeout_seconds"],
    }
    dump_json(phase_dir / "invocation.json", invocation)
    log_path = phase_dir / "process.log"
    environment = os.environ.copy()
    environment.update(resolved["env"])
    started = time.monotonic()
    timed_out = False
    interrupted = False

    with log_path.open("w", encoding="utf-8", errors="replace") as log_handle:
        process = subprocess.Popen(
            resolved["argv"],
            cwd=resolved["cwd"],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            start_new_session=True,
        )

        def copy_output() -> None:
            assert process.stdout is not None
            for line in process.stdout:
                log_handle.write(line)
                log_handle.flush()
                if not quiet:
                    sys.stdout.write(line)
                    sys.stdout.flush()

        reader = threading.Thread(target=copy_output, name=f"log-{resolved['id']}")
        reader.start()
        try:
            process.wait(timeout=resolved["timeout_seconds"])
        except subprocess.TimeoutExpired:
            timed_out = True
            terminate_group(process)
        except KeyboardInterrupt:
            interrupted = True
            terminate_group(process)
        finally:
            reader.join(timeout=15)
            if reader.is_alive():
                raise RegressionError(f"log reader did not stop for {resolved['id']}")

    duration = time.monotonic() - started
    returncode = process.returncode if process.returncode is not None else -1
    passed, gate_results = evaluate_gates(
        resolved["gates"], log_path, returncode, timed_out or interrupted
    )
    result = {
        "phase": resolved["id"],
        "started_at": invocation["started_at"],
        "finished_at": utc_now(),
        "duration_seconds": round(duration, 6),
        "returncode": returncode,
        "timed_out": timed_out,
        "interrupted": interrupted,
        "status": "passed" if passed else "failed",
        "gates": gate_results,
        "process_log": "process.log",
    }
    dump_json(phase_dir / "result.json", result)
    if interrupted:
        raise KeyboardInterrupt
    return result


def write_checksums(run_dir: Path) -> int:
    checksum_path = run_dir / "SHA256SUMS"
    symlinks = sorted(path for path in run_dir.rglob("*") if path.is_symlink())
    if symlinks:
        names = ", ".join(str(path.relative_to(run_dir)) for path in symlinks)
        raise RegressionError(f"refusing to seal symlinks in evidence: {names}")
    files = sorted(
        path
        for path in run_dir.rglob("*")
        if path.is_file() and not path.is_symlink() and path != checksum_path
    )
    with checksum_path.open("w") as handle:
        for path in files:
            relative = path.relative_to(run_dir).as_posix()
            handle.write(f"{sha256(path)}  {relative}\n")
    return len(files)


def host_metadata() -> dict[str, Any]:
    uname = os.uname()
    return {
        "captured_at": utc_now(),
        "hostname": uname.nodename,
        "kernel": {
            "sysname": uname.sysname,
            "release": uname.release,
            "version": uname.version,
            "machine": uname.machine,
        },
        "platform": platform.platform(),
        "python": sys.version,
        "cpu_count": os.cpu_count(),
        "uid": os.getuid(),
        "gid": os.getgid(),
    }


def select_phases(
    manifest: dict[str, Any], tier_args: list[str], phase_args: list[str]
) -> list[str]:
    selected: list[str] = []
    if not tier_args and not phase_args:
        tier_args = [manifest["default_tier"]]
    for tier in tier_args:
        if tier not in manifest["tiers"]:
            raise RegressionError(f"unknown tier: {tier}")
        selected.extend(manifest["tiers"][tier])
    for phase in phase_args:
        if phase not in manifest["phases"]:
            raise RegressionError(f"unknown phase: {phase}")
        selected.append(phase)
    return list(dict.fromkeys(selected))


def preflight(
    manifest: dict[str, Any],
    selected: list[str],
    run_dir: Path,
    timeout_override: int | None,
) -> tuple[list[dict[str, Any]], list[str]]:
    resolved_phases = []
    problems = []
    for phase_id in selected:
        phase = manifest["phases"][phase_id]
        try:
            resolved = resolve_phase(phase_id, phase, run_dir, timeout_override)
            errors, evidence = check_resolved(resolved)
            resolved["prerequisite_evidence"] = evidence
            if not errors:
                resolved["revision_evidence"] = capture_revisions(
                    resolved["revision_roots"]
                )
            resolved_phases.append(resolved)
            problems.extend(f"{phase_id}: {error}" for error in errors)
        except RegressionError as exc:
            problems.append(f"{phase_id}: {exc}")
    return resolved_phases, problems


def assert_inputs_unchanged(resolved: dict[str, Any]) -> None:
    errors, evidence = check_resolved(resolved)
    if errors:
        raise RegressionError(
            f"{resolved['id']} prerequisites changed after preflight: "
            + "; ".join(errors)
        )
    if evidence != resolved["prerequisite_evidence"]:
        raise RegressionError(
            f"{resolved['id']} prerequisite hashes or metadata changed after preflight"
        )
    revisions = capture_revisions(resolved["revision_roots"])
    if revisions != resolved["revision_evidence"]:
        raise RegressionError(
            f"{resolved['id']} source revision or tracked diff changed after preflight"
        )


def list_manifest(manifest: dict[str, Any], manifest_path: Path) -> int:
    fake_run = DEFAULT_OUTPUT_ROOT / "LIST-ONLY"
    tier_membership: dict[str, list[str]] = {phase: [] for phase in manifest["phases"]}
    for tier, members in manifest["tiers"].items():
        for phase in members:
            tier_membership[phase].append(tier)
    print(f"Manifest: {manifest_path}")
    print(f"Default tier: {manifest['default_tier']}")
    print("Tiers:")
    for tier, members in manifest["tiers"].items():
        print(f"  {tier}: {', '.join(members)}")
    print("Phases:")
    for phase_id, phase in manifest["phases"].items():
        if phase["status"] == "planned":
            readiness = f"planned: {phase['reason']}"
            timeout = None
        else:
            resolved = resolve_phase(phase_id, phase, fake_run, None)
            errors, _ = check_resolved(resolved)
            readiness = "ready" if not errors else "missing: " + "; ".join(errors)
            timeout = str(phase["timeout_seconds"])
        tiers = ",".join(tier_membership[phase_id]) or "-"
        timeout_text = f"{timeout:>4}s" if timeout is not None else "    -"
        print(f"  {phase_id:27} timeout={timeout_text} tiers={tiers}")
        print(f"    {readiness}")
        print(f"    {phase['description']}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--list", action="store_true", help="list phases and live prerequisite state")
    parser.add_argument("--tier", action="append", default=[], help="select a declared tier; repeatable")
    parser.add_argument("--phase", action="append", default=[], help="select one phase; repeatable")
    parser.add_argument("--dry-run", action="store_true", help="validate and print commands without creating output")
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--run-id", help="safe unique directory name under the output root")
    parser.add_argument("--timeout-seconds", type=int, help="explicit timeout override for every selected phase")
    parser.add_argument("--keep-going", action="store_true", help="continue later phases after a failed gate")
    parser.add_argument("--quiet", action="store_true", help="retain process logs without streaming them")
    args = parser.parse_args()
    if args.timeout_seconds is not None and not 1 <= args.timeout_seconds <= 86400:
        parser.error("--timeout-seconds must be in 1..86400")
    if args.run_id and not SAFE_RUN_ID.fullmatch(args.run_id):
        parser.error("--run-id must match [A-Za-z0-9][A-Za-z0-9_.-]{0,95}")
    return args


def main() -> int:
    args = parse_args()
    manifest_path = args.manifest.resolve()
    manifest = load_manifest(manifest_path)
    if args.list:
        return list_manifest(manifest, manifest_path)

    selected = select_phases(manifest, args.tier, args.phase)
    run_id = args.run_id or default_run_id()
    output_root = args.output_root.resolve()
    run_dir = output_root / run_id
    resolved_phases, problems = preflight(
        manifest, selected, run_dir, args.timeout_seconds
    )
    if problems:
        print("Preflight failed; no phase was started:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 2

    print(f"Selected phases: {', '.join(selected)}")
    for resolved in resolved_phases:
        print(
            f"  {resolved['id']}: timeout={resolved['timeout_seconds']}s "
            f"cwd={resolved['cwd']}"
        )
        print(f"    {shlex.join(resolved['argv'])}")
    if args.dry_run:
        print("Dry run passed; no output directory was created and no command was run.")
        return 0

    if run_dir.exists():
        raise RegressionError(f"refusing to reuse output directory: {run_dir}")
    run_dir.mkdir(parents=True)
    shutil.copy2(SCRIPT, run_dir / "runner.py")
    shutil.copy2(REGRESSION_ROOT / "verify.py", run_dir / "verify.py")
    shutil.copy2(INPUT_AUDITOR, run_dir / "audit-inputs.py")
    shutil.copy2(manifest_path, run_dir / "manifest.snapshot.json")
    dump_json(run_dir / "host.json", host_metadata())
    dump_json(
        run_dir / "preflight.json",
        {
            "captured_at": utc_now(),
            "selected": selected,
            "phases": [
                {
                    "phase": phase["id"],
                    "prerequisites": phase["prerequisite_evidence"],
                    "revisions": phase["revision_evidence"],
                }
                for phase in resolved_phases
            ],
        },
    )
    run_record = {
        "schema_version": 1,
        "run_id": run_id,
        "started_at": utc_now(),
        "finished_at": None,
        "status": "running",
        "manifest": str(manifest_path),
        "manifest_sha256": sha256(manifest_path),
        "runner_sha256": sha256(SCRIPT),
        "verifier_sha256": sha256(REGRESSION_ROOT / "verify.py"),
        "auditor_sha256": sha256(INPUT_AUDITOR),
        "selected": selected,
        "results": [],
    }
    dump_json(run_dir / "run.json", run_record)

    interrupted = False
    try:
        for resolved in resolved_phases:
            print(f"\n=== {resolved['id']} ===")
            assert_inputs_unchanged(resolved)
            result = run_phase(resolved, run_dir / resolved["id"], args.quiet)
            # A long-running simulator must be attributed to the same binary,
            # payload, manifests, and tracked source state that preflight saw.
            # Checking only before launch leaves a race with concurrent rebuilds.
            assert_inputs_unchanged(resolved)
            run_record["results"].append(result)
            dump_json(run_dir / "run.json", run_record)
            print(f"=== {resolved['id']}: {result['status']} ({result['duration_seconds']:.1f}s) ===")
            if result["status"] != "passed" and not args.keep_going:
                break
    except KeyboardInterrupt:
        interrupted = True
        print("Regression interrupted; partial evidence will be sealed.", file=sys.stderr)
    except Exception as exc:  # retain unexpected orchestration failures in the bundle
        run_record["orchestrator_error"] = f"{type(exc).__name__}: {exc}"
        print(run_record["orchestrator_error"], file=sys.stderr)

    all_passed = (
        not interrupted
        and "orchestrator_error" not in run_record
        and len(run_record["results"]) == len(selected)
        and all(result["status"] == "passed" for result in run_record["results"])
    )
    run_record["finished_at"] = utc_now()
    run_record["status"] = "passed" if all_passed else "failed"
    run_record["interrupted"] = interrupted
    dump_json(run_dir / "run.json", run_record)
    file_count = write_checksums(run_dir)
    print(f"Evidence: {run_dir}")
    print(f"Checksummed files: {file_count}")
    print(f"Overall status: {run_record['status']}")
    return 0 if all_passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RegressionError as exc:
        print(f"regression error: {exc}", file=sys.stderr)
        raise SystemExit(2)

