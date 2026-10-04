#!/usr/bin/env python3
"""Validate the UAT artifact manifest that a PROD promotion consumes.

PROD must run the exact images UAT accepted (plan §7, GAP-16, TC-10). This
validator is the single gate for that contract and fails closed:

* the UAT Hybrid run must be completed with conclusion ``success`` (a failed,
  cancelled, skipped or still-running run is refused);
* the manifest must come from an immutable ``daily-build-*`` UAT snapshot, never
  from ``main`` or another moving ref, and PROD must use a formal ``v*`` tag;
* every promoted Cloud Run service appears exactly once with a ``sha256``
  digest, a UAT Artifact Registry image and the 40-hex source commit.

On success it prints the normalized manifest as one line of JSON, which is the
only form the PROD dispatch forwards.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

SNAPSHOT_TAG = re.compile(r"^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$")
RELEASE_TAG = re.compile(r"^v([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{2}\.[0-9]{2})(-r[1-9][0-9]*)?$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
SOURCE_SHA = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_SERVICES = ("accounts", "billing-service", "content-service")
HYBRID_WORKFLOW_PATH = ".github/workflows/hybrid-orchestrator.yml"
GATE_CHECKS = {
    "smooth_upgrade": (
        "data_and_relations_preserved", "application_healthy", "runtime_digest_verified",
        "migration_idempotent",
    ),
    "original_user_login": (
        "uat_login_executed", "original_password_compatible", "permissions_verified",
    ),
    "subscriptions_preserved": (
        "plan_status_validity_entitlements_unchanged", "api_or_page_readable",
        "quota_not_reset", "no_duplicate_charge",
    ),
}


class Refused(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Refused(message)


def check_uat_run(run: dict, run_id: str) -> None:
    require(str(run.get("id")) == run_id, f"UAT run record is for {run.get('id')}, expected {run_id}")
    require(
        str(run.get("path", "")).split("@", 1)[0] == HYBRID_WORKFLOW_PATH,
        "UAT evidence must come from the Hybrid Orchestrator run",
    )
    require(run.get("status") == "completed", f"UAT Hybrid run {run_id} is {run.get('status')}, not completed")
    require(
        run.get("conclusion") == "success",
        f"UAT Hybrid run {run_id} concluded {run.get('conclusion')}, not success",
    )
    require(run.get("head_branch") == "main" and run.get("event") == "workflow_dispatch",
            "UAT promotion evidence must be produced by a manual Hybrid run on protected main")


def check_upgrade_acceptance(manifest: dict, tag: str, images: list[dict]) -> dict:
    """Business evidence is separate from deployment success and artifact identity.

    The accepted artifact must carry this record. No caller flag, SQL-only
    fingerprint, empty sample, or historical green deployment fills it in.
    The full record survives normalization and artifact provenance comparison.
    """
    proof = manifest.get("upgrade_acceptance")
    require(isinstance(proof, dict), "BLOCKED: missing UAT upgrade/login/subscription evidence")
    require(proof.get("schema") == 1 and proof.get("environment") == "uat",
            "upgrade acceptance must use schema 1 and environment uat")
    require(proof.get("snapshot_tag") == tag, "upgrade evidence belongs to a different target tag")
    require(proof.get("images") == images, "upgrade evidence does not cover the promoted image digests")
    baseline = proof.get("baseline")
    require(isinstance(baseline, dict), "BLOCKED: missing old-version UAT baseline")
    old_tag = baseline.get("snapshot_tag")
    require(isinstance(old_tag, str) and (SNAPSHOT_TAG.fullmatch(old_tag) or RELEASE_TAG.fullmatch(old_tag)),
            "baseline must identify an immutable old release tag")
    require(old_tag != tag, "same-tag redeployment is not an old-version upgrade rehearsal")
    for field in ("existing_users", "subscriptions"):
        count = baseline.get(field)
        require(type(count) is int and count > 0, f"BLOCKED: baseline {field} must be non-empty")
    migration = proof.get("migration")
    require(isinstance(migration, dict), "BLOCKED: missing migration evidence")
    expected = migration.get("expected_version")
    require(type(expected) is int and expected > 0, "migration requires the artifact's explicit target version")
    before = migration.get("before_version")
    require(type(before) is int and 0 < before <= expected and migration.get("before_dirty") is False,
            "BLOCKED: old schema requires a clean, recognized migration baseline")
    require(type(migration.get("actual_version")) is int and migration["actual_version"] == expected,
            "migration did not reach the artifact's exact target version")
    require(migration.get("dirty") is False, "migration dirty must be false")
    gates = proof.get("gates")
    require(isinstance(gates, dict), "BLOCKED: missing business acceptance gates")
    for name, checks in GATE_CHECKS.items():
        gate = gates.get(name)
        require(isinstance(gate, dict) and gate.get("status") == "passed",
                f"BLOCKED: {name} was not demonstrated")
        for check in checks:
            require(gate.get(check) is True, f"BLOCKED: {name}.{check} was not demonstrated")
        urls = gate.get("evidence_urls")
        require(isinstance(urls, list) and len(urls) > 0 and all(
            isinstance(url, str) and re.fullmatch(
                r"https://github\.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/[1-9][0-9]*(/job/[1-9][0-9]*)?", url
            ) for url in urls), f"BLOCKED: {name} needs reviewable UAT run evidence")
    # Only publish the contract's non-secret fields, never arbitrary payload
    # supplied alongside evidence (credentials and row fingerprints stay out).
    return {
        "schema": 1, "environment": "uat", "snapshot_tag": tag, "images": images,
        "baseline": {key: baseline[key] for key in ("snapshot_tag", "existing_users", "subscriptions")},
        "migration": {key: migration[key] for key in (
            "before_version", "before_dirty", "expected_version", "actual_version", "dirty")},
        "gates": {name: {"status": "passed", **{check: gates[name][check] for check in checks},
                         "evidence_urls": gates[name]["evidence_urls"]}
                  for name, checks in GATE_CHECKS.items()},
    }


def normalize(manifest: dict, snapshot_tag: str, uat_run_id: str | None) -> dict:
    require(manifest.get("schema") == 1, "manifest schema must be 1")
    require(manifest.get("environment") == "uat", "only a UAT-accepted manifest can be promoted")
    tag = manifest.get("snapshot_tag")
    require(isinstance(tag, str) and SNAPSHOT_TAG.match(tag) is not None,
            f"manifest snapshot tag {tag!r} is not an immutable daily-build tag (main or a branch is refused)")
    if snapshot_tag:
        require(tag == snapshot_tag, f"manifest snapshot tag {tag} does not match the accepted UAT tag {snapshot_tag}")
    run_id = uat_run_id or str(manifest.get("uat_run_id", ""))
    require(re.fullmatch(r"[1-9][0-9]*", run_id or "") is not None, "manifest must name the accepted UAT Hybrid run")
    if manifest.get("uat_run_id") not in (None, ""):
        require(str(manifest["uat_run_id"]) == run_id, "manifest names a different UAT Hybrid run")

    images = manifest.get("images")
    require(isinstance(images, list), "manifest images must be a list")
    services = [image.get("service") if isinstance(image, dict) else None for image in images]
    require(sorted(services) == sorted(REQUIRED_SERVICES) and len(set(services)) == len(services),
            f"manifest must list each of {', '.join(REQUIRED_SERVICES)} exactly once")
    normalized = []
    for image in sorted(images, key=lambda item: item["service"]):
        service = image["service"]
        path = re.compile(rf"^[a-z0-9-]+-docker\.pkg\.dev/[a-z][a-z0-9-]{{4,28}}[a-z0-9]/serverless/{re.escape(service)}$")
        require(isinstance(image.get("image"), str) and path.match(image["image"]) is not None,
                f"{service}: image must be its UAT Artifact Registry repository")
        require(image.get("tag") == tag, f"{service}: image tag must be the UAT snapshot tag {tag}")
        require(isinstance(image.get("digest"), str) and DIGEST.match(image["digest"]) is not None,
                f"{service}: digest must be sha256:<64 hex>")
        require(isinstance(image.get("source_sha"), str) and SOURCE_SHA.match(image["source_sha"]) is not None,
                f"{service}: source_sha must be a full commit SHA")
        require(image.get("source_repository") == f"ai-workspace-services/{service}",
                f"{service}: source repository must be ai-workspace-services/{service}")
        normalized.append({key: image[key] for key in ("service", "image", "tag", "digest", "source_repository", "source_sha")})
    proof = check_upgrade_acceptance(manifest, tag, normalized)
    return {"schema": 1, "environment": "uat", "snapshot_tag": tag, "uat_run_id": run_id,
            "images": normalized, "upgrade_acceptance": proof}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--snapshot-tag", default="", help="accepted UAT snapshot tag")
    parser.add_argument("--uat-run-id", default="", help="accepted UAT Hybrid run id")
    parser.add_argument("--uat-run-json", type=Path, help="GitHub API record of the UAT Hybrid run")
    parser.add_argument("--accepted-manifest", type=Path, help="manifest downloaded from that UAT run's artifact")
    parser.add_argument("--release-tag", default="", help="PROD release tag the manifest is promoted to")
    args = parser.parse_args()
    try:
        try:
            manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise Refused(f"cannot read the promotion manifest: {error}") from error
        require(isinstance(manifest, dict), "manifest must be a JSON object")
        if args.release_tag:
            require(RELEASE_TAG.match(args.release_tag) is not None,
                    f"PROD release tag {args.release_tag!r} is not a formal v* tag")
        result = normalize(manifest, args.snapshot_tag, args.uat_run_id or None)
        if args.uat_run_json:
            check_uat_run(json.loads(args.uat_run_json.read_text(encoding="utf-8")), result["uat_run_id"])
        if args.accepted_manifest:
            try:
                accepted = json.loads(args.accepted_manifest.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise Refused(f"cannot read the UAT run artifact: {error}") from error
            require(isinstance(accepted, dict), "UAT run artifact must be a JSON object")
            proof = normalize(accepted, result["snapshot_tag"], result["uat_run_id"])
            require(result == proof, "promotion manifest differs from the successful UAT run artifact")
    except Refused as error:
        print(f"::error::Refusing PROD promotion: {error}.", file=sys.stderr)
        return 1
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
