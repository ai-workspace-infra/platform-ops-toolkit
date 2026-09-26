#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/scripts/serverless/wait_for_artifact_image.sh"

[[ -x "${script}" ]] || {
  echo "wait_for_artifact_image.sh must be executable" >&2
  exit 1
}

python3 - "${repo_root}/.github/workflows/serverless-orchestrator.yml" <<'PY'
from pathlib import Path
import sys
import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
jobs = workflow["jobs"]
cloud_run = jobs["cloud_run"]
steps = cloud_run["steps"]
wait = next((step for step in steps if step.get("name") == "Wait for service image in Artifact Registry"), None)
if wait is None:
    raise SystemExit("cloud_run must wait for the exact Artifact Registry image before deployment")
if wait.get("run") != "./.github/scripts/serverless/wait_for_artifact_image.sh":
    raise SystemExit("cloud_run image readiness step must use the shared wait script")
env = wait.get("env", {})
for key in ("GCP_PROJECT_ID", "GCP_ARTIFACT_REGISTRY_REGION", "CLOUD_RUN_SERVICE", "IMAGE_TAG"):
    if key not in env:
        raise SystemExit(f"image readiness step must pass {key}")

gitops = next((step for step in steps if step.get("name") == "Read GitOps GCP target"), None)
if gitops is None:
    raise SystemExit("cloud_run must load project and region from the GitOps GCP manifest")
if gitops.get("id") != "gitops_gcp":
    raise SystemExit("GitOps GCP target step must expose the gitops_gcp outputs")
env = gitops.get("env", {})
if "GCP_GITOPS_MANIFEST" not in env:
    raise SystemExit("GitOps GCP target step must receive the manifest path")

vault = next((step for step in steps if step.get("name") == "Authenticate to Vault with GitHub OIDC"), None)
secrets = str((vault or {}).get("with", {}).get("secrets", ""))
if "GCP_WORKLOAD_IDENTITY_PROVIDER" not in secrets or "GCP_SERVICE_ACCOUNT_EMAIL" not in secrets:
    raise SystemExit("cloud_run Vault contract must provide only the WIF provider and deploy Service Account")
if "GCP_PROJECT_ID | GCP_PROJECT_ID" in secrets or "GCP_REGION | GCP_REGION" in secrets:
    raise SystemExit("cloud_run must not duplicate GitOps project or region in Vault")
PY

echo "serverless_artifact_image_wait_test: PASS"
