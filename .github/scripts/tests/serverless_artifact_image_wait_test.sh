#!/usr/bin/env bash
set -euo pipefail

# Registry readiness is an IaC Modules operation. This test pins the Toolkit
# side of that contract: cloud_run checks out the reviewed IaC commit, calls the
# shared wait script with the exact repository URI built from GitOps, and keeps
# the build/promote -> wait -> deploy ordering.
#
# IAC_REGISTRY_TEST_ROOT points at an iac_modules tree containing
# scripts/pipeline (CI: the pipeline-contract/iac_modules checkout).

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
iac_root="${IAC_REGISTRY_TEST_ROOT:-${repo_root}/pipeline-contract/iac_modules}"
script="${iac_root}/scripts/pipeline/artifact-registry-wait.sh"

[[ -x "${script}" ]] || {
  echo "artifact-registry-wait.sh must exist and be executable under IAC_REGISTRY_TEST_ROOT (${iac_root})" >&2
  exit 1
}

python3 - "${repo_root}/.github/workflows/serverless-orchestrator.yml" <<'PY'
from pathlib import Path
import re
import sys
import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
jobs = workflow["jobs"]
cloud_run = jobs["cloud_run"]
steps = cloud_run["steps"]
names = [step.get("name") for step in steps]

wait = next((step for step in steps if step.get("name") == "Wait for service image in Artifact Registry"), None)
if wait is None:
    raise SystemExit("cloud_run must wait for the exact Artifact Registry image before deployment")
if wait.get("run") != "./iac_modules/scripts/pipeline/artifact-registry-wait.sh":
    raise SystemExit("cloud_run image readiness step must call the IaC Modules wait script")
if wait.get("if"):
    raise SystemExit("image readiness must run for both UAT builds and PROD promotions")
env = wait.get("env", {})
expected_repository = ("${{ steps.gitops_gcp.outputs.region }}-docker.pkg.dev/"
                       "${{ steps.gitops_gcp.outputs.project_id }}/serverless/${{ matrix.service }}")
if env.get("ARTIFACT_IMAGE_REPOSITORY") != expected_repository:
    raise SystemExit("image readiness must receive the full <region>-docker.pkg.dev/<project>/serverless/<service> URI from GitOps outputs")
if env.get("IMAGE_TAG") != "${{ inputs.tag_ref }}":
    raise SystemExit("image readiness must wait for the release tag")
for retired in ("GCP_PROJECT_ID", "GCP_ARTIFACT_REGISTRY_REGION", "CLOUD_RUN_SERVICE"):
    if retired in env:
        raise SystemExit(f"image readiness no longer takes {retired}; the repository URI is the input")

# The IaC commit is a reviewed pin and is checked out, without credentials,
# before either registry operation runs.
checkout_name = "Checkout IaC Modules registry operations"
checkout = next((step for step in steps if step.get("name") == checkout_name), None)
if checkout is None:
    raise SystemExit("cloud_run must check out iac_modules before calling its registry scripts")
options = checkout.get("with", {})
if not str(checkout.get("uses", "")).startswith("actions/checkout@"):
    raise SystemExit("the IaC Modules checkout must use actions/checkout")
if options.get("repository") != "ai-workspace-infra/iac_modules" or options.get("path") != "iac_modules":
    raise SystemExit("the IaC Modules checkout must land in iac_modules/")
if not re.fullmatch(r"[0-9a-f]{40}", str(options.get("ref", ""))):
    raise SystemExit("the IaC Modules checkout must be pinned to a 40-character commit SHA")
if options.get("persist-credentials") is not False:
    raise SystemExit("the IaC Modules checkout must not persist credentials")
if checkout.get("if"):
    raise SystemExit("the IaC Modules checkout must be unconditional (UAT waits, PROD promotes)")
promote_name = "Promote the UAT-accepted image by digest"
if not (names.index(checkout_name) < names.index(promote_name) < names.index("Wait for service image in Artifact Registry")):
    raise SystemExit("checkout of iac_modules must precede promote, which must precede wait")

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
