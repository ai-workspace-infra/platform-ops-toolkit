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
    return {"schema": 1, "environment": "uat", "snapshot_tag": tag, "uat_run_id": run_id, "images": normalized}


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
