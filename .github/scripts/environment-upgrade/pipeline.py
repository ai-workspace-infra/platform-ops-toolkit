#!/usr/bin/env python3
"""Fail-closed release orchestration; offline rehearsal is never live evidence.

This module does not implement cloud/DB mutations. Fixed, reviewed adapters
must be registered before live preflight/upgrade can run. Raw adapter output
and private receipts are never published or echoed to Actions logs.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = Path(__file__).resolve().parent
PHASES = ("preflight", "backup", "migration", "promotion", "verification")
REHEARSAL_PHASES = PHASES + ("rollback", "repromotion", "final_verification")
SERVICES = ("accounts", "billing-service", "content-service")
SHA = re.compile(r"[0-9a-f]{64}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
SPEC = importlib.util.spec_from_file_location(
    "promotion_gate", ROOT / ".github/scripts/snapshots/verify-promotion-manifest.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class Blocked(Exception):
    pass


def require(condition, reason):
    if not condition:
        raise Blocked(reason)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def identity(candidate):
    return hashlib.sha256(canonical(candidate).encode()).hexdigest()


def read_json(path):
    require(path.is_file() and not path.is_symlink(), "missing or unsafe evidence file")
    return json.loads(path.read_text())


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(canonical(value) + "\n")
    path.chmod(0o600)


def inputs(env):
    target = env.get("DEPLOY_ENV")
    mode = env.get("UPGRADE_MODE")
    require(target in ("uat", "prod"), "explicit environment must be uat or prod")
    require(mode in ("preflight", "rehearsal", "upgrade"), "invalid operation mode")
    require(mode != "rehearsal" or target == "uat", "rehearsal is UAT-only; PROD rehearsal is forbidden")
    tag = env.get("RELEASE_TAG", "")
    pattern = GATE.RELEASE_TAG if target == "prod" else GATE.SNAPSHOT_TAG
    require(pattern.fullmatch(tag) is not None, "immutable environment-compatible tag required")
    before, after = env.get("EXPECTED_SCHEMA_VERSION", ""), env.get("TARGET_SCHEMA_VERSION", "")
    require(re.fullmatch(r"[1-9][0-9]{0,17}", before) is not None
            and re.fullmatch(r"[1-9][0-9]{0,17}", after) is not None,
            "explicit positive schema versions required")
    require(int(after) > int(before), "target schema version must increase")
    checksum = env.get("MIGRATION_SHA256", "")
    require(SHA.fullmatch(checksum) is not None, "reviewed migration SHA256 required")
    require(re.fullmatch(r"[1-9][0-9]*", env.get("CANDIDATE_RUN_ID", "")) is not None,
            "completed UAT Hybrid candidate_run_id required")
    ref = env.get("GITHUB_REF", "")
    if target == "prod":
        require(ref == "refs/tags/" + tag, "PROD must dispatch from its release tag")
    else:
        require(ref == "refs/heads/main", "live UAT must dispatch reviewed workflow on main")
    return {"schema": 1, "environment": target, "mode": mode, "release_tag": tag,
            "expected_schema_version": int(before), "target_schema_version": int(after),
            "migration_sha256": checksum, "backup_backend": "selfhost-web-saas",
            "backup_environment": target}


def command(args, **kwargs):
    # Never propagate tool stderr (may contain DSNs, provider keys or row data).
    result = subprocess.run(args, capture_output=True, text=True, timeout=300, **kwargs)
    require(result.returncode == 0, "source provenance or artifact retrieval failed")
    return result.stdout


def resolve_candidate(env):
    candidate = inputs(env)
    repository = env.get("GITHUB_REPOSITORY", "")
    require(repository == "ai-workspace-infra/platform-ops-toolkit", "unexpected release repository")
    if candidate["environment"] == "prod":
        protected = json.loads(command(["gh", "api", f"repos/{repository}/environments/prod"]))
        rules = protected.get("protection_rules", [])
        require(any(rule.get("type") == "required_reviewers" and rule.get("prevent_self_review") is True
                    and len(rule.get("reviewers", [])) > 0 for rule in rules),
                "PROD environment must require an independent reviewer before dispatch")
    run_id = env["CANDIDATE_RUN_ID"]
    run = json.loads(command(["gh", "api", f"repos/{repository}/actions/runs/{run_id}"]))
    require(run.get("repository", {}).get("full_name") == repository, "foreign candidate run")
    try:
        GATE.check_uat_run(run, run_id)
    except GATE.Refused as exc:
        raise Blocked("UAT run provenance is missing or invalid") from exc
    with tempfile.TemporaryDirectory() as directory:
        command(["gh", "run", "download", run_id, "--repo", repository,
                 "--name", "uat-artifact-manifest", "--dir", directory])
        manifest = read_json(Path(directory) / "uat-artifact-manifest.json")
    snapshot = manifest.get("snapshot_tag", "")
    if candidate["environment"] == "prod":
        try:
            accepted = GATE.normalize(manifest, snapshot, run_id)
        except GATE.Refused as exc:
            raise Blocked("UAT business acceptance is missing or invalid") from exc
        expected_tag = "v" + re.sub(r"^(uat-)?daily-build-", "", snapshot)
        require(candidate["release_tag"] == expected_tag, "PROD tag must promote the exact accepted UAT snapshot")
        migration = accepted["upgrade_acceptance"]["migration"]
        require(migration["before_version"] == candidate["expected_schema_version"]
                and migration["actual_version"] == candidate["target_schema_version"],
                "selected migration versions differ from UAT acceptance")
        require(manifest.get("migration_sha256") == candidate["migration_sha256"],
                "UAT artifact must bind the reviewed migration checksum")
        # Require annotated control-plane tags, never lightweight or moving refs.
        ref = json.loads(command(["gh", "api", f"repos/{repository}/git/ref/tags/{expected_tag}"]))
        require(ref.get("object", {}).get("type") == "tag", "annotated PROD release tag required")
        tag_sha = ref["object"]["sha"]
        require(re.fullmatch(r"[0-9a-f]{40}", tag_sha) is not None, "invalid annotated tag identity")
        tag = json.loads(command(["gh", "api", f"repos/{repository}/git/tags/{tag_sha}"]))
        require(tag.get("object", {}).get("type") == "commit"
                and tag["object"]["sha"] == env.get("GITHUB_SHA"),
                "release tag commit differs from dispatched workflow")
    else:
        require(snapshot == candidate["release_tag"], "candidate run belongs to a different UAT tag")
    # UAT needs build provenance, but must be able to create its first business
    # acceptance. Do not require the future acceptance before UAT is upgraded.
    images = manifest.get("images")
    require(isinstance(images, list) and len(images) == len(SERVICES), "complete candidate images required")
    require(sorted(item.get("service", "") for item in images) == sorted(SERVICES), "candidate service set differs")
    sanitized = []
    for item in images:
        service = item["service"]
        require(DIGEST.fullmatch(item.get("digest", "")) is not None, "invalid image digest")
        require(re.fullmatch(r"[0-9a-f]{40}", item.get("source_sha", "")) is not None, "full source SHA required")
        require(item.get("source_repository") == "ai-workspace-services/" + service, "foreign image source")
        require(item.get("tag") == snapshot, "image belongs to a different tag")
        require(re.fullmatch(r"[a-z0-9-]+-docker\.pkg\.dev/[a-z0-9-]+/serverless/" + service,
                             item.get("image", "")) is not None, "unexpected image repository")
        sanitized.append({key: item[key] for key in
                          ("service", "image", "digest", "source_repository", "source_sha", "tag")})
    candidate.update({"evidence_kind": "live_candidate", "uat_run_id": run_id,
                      "run_id": env["GITHUB_RUN_ID"], "images": sorted(sanitized, key=lambda i: i["service"])})
    return candidate


def registered_adapters(candidate, registry=None):
    registry = read_json(DIRECTORY / "adapters.json") if registry is None else registry
    require(registry.get("schema") == 2, "unsupported adapter registry")
    require(candidate["evidence_kind"] == "live_candidate", "rehearsal cannot authorize live execution")
    needed = phase_sequence(candidate) if candidate["mode"] != "preflight" else ("preflight",)
    selected = registry.get(candidate["environment"], {})
    declared_phases = selected.get("phases", [])
    require(isinstance(declared_phases, list) and all(phase in REHEARSAL_PHASES for phase in declared_phases),
            "invalid phase registration")
    missing = [phase for phase in needed if phase not in declared_phases]
    require(not missing, "reviewed live adapters not registered: " + ", ".join(missing))
    item = selected.get("delegate")
    require(isinstance(item, dict), "single reviewed playbooks delegate is required")
    expected_path = ".github/scripts/environment-upgrade/delegate.sh"
    require(item.get("path") == expected_path, "delegate must use its fixed control-plane path")
    path = ROOT / expected_path
    require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(ROOT),
            "reviewed delegate missing or symlinked outside repository")
    require(SHA.fullmatch(item.get("sha256", "")) is not None
            and hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"],
            "delegate checksum differs from reviewed registration")
    return {phase: path for phase in needed}


def digests(candidate):
    return {item["service"]: item["digest"] for item in candidate["images"]}


def phase_sequence(candidate):
    return REHEARSAL_PHASES if candidate["mode"] == "rehearsal" else PHASES


def validate_receipt(candidate, phase, receipt, previous):
    require(receipt.get("schema") == 1 and receipt.get("phase") == phase, "invalid phase receipt")
    require(receipt.get("candidate_sha256") == identity(candidate), "receipt belongs to another candidate or run")
    require(receipt.get("environment") == candidate["environment"], "cross-environment receipt refused")
    require(receipt.get("status") == "passed", "adapter did not demonstrate phase success")
    required = {
        "preflight": ("clean", "old_application_healthy", "permissions_baseline_captured", "ledger_baseline_captured"),
        "backup": ("encrypted", "durable", "download_verified", "isolated_restore_verified", "restored_data_matches",
                   "fallback_runtime_preserved", "fallback_database_preserved", "gitops_backup_host_verified"),
        "migration": ("dirty_false", "database_lock_held", "bounded_lock_wait", "bounded_execution",
                      "reviewed_additive_sql", "old_application_compatible", "data_preserved", "idempotent"),
        "promotion": ("same_digest", "no_rebuild", "no_shared_bootstrap", "no_data_sync", "fallback_preserved"),
        "verification": ("original_password_login", "permissions_preserved", "subscription_entitlements_preserved",
                         "quota_preserved", "financial_ledger_preserved", "usage_ledger_preserved",
                         "no_real_payment_or_refund", "healthy", "runtime_digest_verified"),
        "rollback": ("application_only", "no_database_restore", "schema_retained", "healthy", "old_application_compatible"),
        "repromotion": ("same_digest", "no_rebuild", "no_shared_bootstrap", "no_data_sync", "fallback_preserved"),
        "final_verification": ("original_password_login", "permissions_preserved", "subscription_entitlements_preserved",
                               "quota_preserved", "financial_ledger_preserved", "usage_ledger_preserved",
                               "no_real_payment_or_refund", "healthy", "runtime_digest_verified"),
    }[phase]
    safe = {"schema": 1, "phase": phase, "candidate_sha256": identity(candidate),
            "environment": candidate["environment"], "status": "passed"}
    for check in required:
        require(receipt.get(check) is True, f"missing execution evidence: {phase}.{check}")
        safe[check] = True
    expected, target = candidate["expected_schema_version"], candidate["target_schema_version"]
    if phase == "preflight":
        require(type(receipt.get("schema_version")) is int and receipt["schema_version"] == expected,
                "starting schema version differs")
        for field in ("existing_users", "subscriptions"):
            require(type(receipt.get(field)) is int and receipt[field] > 0, "nonempty baseline required")
            safe[field] = receipt[field]
        old = receipt.get("rollback_digests", {})
        require(set(old) == set(SERVICES) and all(DIGEST.fullmatch(v) for v in old.values()),
                "complete previous image digests required")
        safe.update(schema_version=expected, rollback_digests=old)
    if phase == "backup":
        require(receipt.get("backup_backend") == "selfhost-web-saas"
                and receipt.get("backup_environment") == candidate["environment"],
                "backup must reside on the same environment's selfhost web-saas fallback host")
        require(SHA.fullmatch(receipt.get("backup_host_identity", "")) is not None,
                "verified environment-local backup host identity required")
        require(re.fullmatch(r"[A-Za-z0-9_-]{1,128}", receipt.get("checkpoint_id", "")) is not None,
                "opaque checkpoint identifier required")
        require(receipt.get("schema_version") == expected, "backup has wrong schema version")
        require(receipt.get("source_database_identity") != receipt.get("restore_database_identity")
                and all(SHA.fullmatch(receipt.get(k, "")) for k in
                        ("source_database_identity", "restore_database_identity")), "restore target must be isolated")
        safe.update(checkpoint_id=receipt["checkpoint_id"], schema_version=expected,
                    source_database_identity=receipt["source_database_identity"],
                    restore_database_identity=receipt["restore_database_identity"],
                    backup_backend="selfhost-web-saas", backup_environment=candidate["environment"],
                    backup_host_identity=receipt["backup_host_identity"])
    if phase == "migration":
        require(receipt.get("before_version") == expected and receipt.get("after_version") == target,
                "migration did not reach the exact target")
        require(receipt.get("migration_sha256") == candidate["migration_sha256"], "migration checksum differs")
        require(receipt.get("checkpoint_id") == previous["backup"]["checkpoint_id"], "migration not bound to verified backup")
        safe.update(before_version=expected, after_version=target,
                    migration_sha256=candidate["migration_sha256"], checkpoint_id=receipt["checkpoint_id"])
    if phase in ("promotion", "verification", "repromotion", "final_verification"):
        require(receipt.get("running_digests") == digests(candidate), "running digests differ from accepted candidate")
        safe["running_digests"] = digests(candidate)
    if phase in ("promotion", "repromotion"):
        require(receipt.get("rollback_digests") == previous["preflight"]["rollback_digests"], "rollback point changed")
        safe["rollback_digests"] = receipt["rollback_digests"]
    if phase in ("verification", "final_verification", "rollback"):
        require(receipt.get("schema_version") == target and receipt.get("dirty") is False, "post-release schema not clean at target")
        safe.update(schema_version=target, dirty=False)
    if phase == "rollback":
        require(candidate["environment"] == "uat" and candidate["mode"] == "rehearsal", "rollback rehearsal is UAT-only")
        require(receipt.get("running_digests") == previous["preflight"]["rollback_digests"], "old digests not restored")
        safe["running_digests"] = receipt["running_digests"]
    return safe


def execute_phase(candidate, phase, public, runner=None):
    require(candidate["mode"] in ("upgrade", "rehearsal") or phase == "preflight", "preflight cannot mutate")
    require(phase in phase_sequence(candidate), "phase is not allowed in requested mode")
    adapters = registered_adapters(candidate)
    previous = {}
    phases = phase_sequence(candidate)
    for required_phase in phases[:phases.index(phase)]:
        receipt = read_json(public / (required_phase + ".json"))
        previous[required_phase] = validate_receipt(candidate, required_phase, receipt, previous)
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / "receipt.json"
        env = dict(os.environ, UPGRADE_CANDIDATE_FILE=str(public / "candidate.json"),
                   UPGRADE_RECEIPT_FILE=str(output), UPGRADE_EVIDENCE_DIR=str(public),
                   UPGRADE_PHASE=phase)
        run = runner or subprocess.run
        result = run(["bash", str(adapters[phase])], env=env, capture_output=True, timeout=7200)
        require(result.returncode == 0, f"{phase} adapter failed; downstream stages blocked (raw output withheld)")
        receipt = validate_receipt(candidate, phase, read_json(output), previous)
        write_json(public / (phase + ".json"), receipt)


def verdict(mode, results):
    required = ["candidate"] + {"rehearsal": ["preflight", "upgrade"], "preflight": ["preflight"],
                                "upgrade": ["preflight", "upgrade"]}[mode]
    require(all(results.get(job, {}).get("result") == "success" for job in required),
            "requested stages failed, were cancelled, or were skipped; no release acceptance")
    return {"rehearsal": "UAT upgrade, application rollback and re-promotion rehearsal passed — NOT a PROD deployment.",
            "preflight": "Read-only preflight passed — database/applications were not upgraded.",
            "upgrade": "Selected environment upgrade and post-release verification passed."}[mode]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("candidate", "capabilities", "phase", "verdict"))
    parser.add_argument("phase", nargs="?", choices=REHEARSAL_PHASES)
    args = parser.parse_args()
    public = Path(os.environ["RUNNER_TEMP"]) / "environment-upgrade/public"
    try:
        if args.operation == "candidate":
            write_json(public / "candidate.json", resolve_candidate(os.environ))
            message = "Candidate validated; no deployment or database mutation performed."
        elif args.operation == "verdict":
            message = verdict(os.environ["UPGRADE_MODE"], json.loads(os.environ["JOB_RESULTS"]))
        else:
            candidate = read_json(public / "candidate.json")
            require(inputs(os.environ) == {key: candidate[key] for key in inputs(os.environ)},
                    "downloaded candidate differs from current request")
            require(candidate.get("run_id") == os.environ.get("GITHUB_RUN_ID"), "candidate belongs to another workflow run")
            if args.operation == "capabilities":
                registered_adapters(candidate)
                message = "All requested execution adapters verified."
            else:
                require(args.phase is not None, "phase required")
                execute_phase(candidate, args.phase, public)
                message = f"{args.phase} execution evidence verified."
        print(message)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                summary.write(message + "\n")
    except (Blocked, ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired):
        # Do not include arbitrary exception strings: tooling or JSON errors
        # can embed private data. Only our own controlled refusal text is safe.
        exc = sys.exc_info()[1]
        message = str(exc) if isinstance(exc, Blocked) else "Invalid or unavailable release evidence; execution blocked."
        print("::error::" + message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
