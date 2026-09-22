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

vault = next((step for step in steps if step.get("name") == "Authenticate to Vault with GitHub OIDC"), None)
secrets = str((vault or {}).get("with", {}).get("secrets", ""))
if "GCP_REGION | GCP_REGION" not in secrets:
    raise SystemExit("cloud_run Vault contract must provide GCP_REGION for the registry readiness check")
PY

echo "serverless_artifact_image_wait_test: PASS"
