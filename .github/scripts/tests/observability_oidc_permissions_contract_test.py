#!/usr/bin/env python3
"""Ensure Observability jobs using Vault can request GitHub OIDC tokens."""

from pathlib import Path
import json
import yaml

root = Path(__file__).resolve().parents[3]
workflow = yaml.safe_load((root / ".github/workflows/observability-server.yml").read_text())

for job_name in ("historical_data", "verify_stores", "verify_target", "dns_switch"):
    permissions = workflow["jobs"][job_name].get("permissions", {})
    assert permissions.get("id-token") == "write", (
        f"{job_name} must have id-token: write for Vault JWT authentication"
    )
    assert permissions.get("contents") == "read", (
        f"{job_name} should retain only read access to repository contents"
    )

    job = workflow["jobs"][job_name]
    roles = [job.get("env", {}).get("VAULT_ROLE", "")]
    roles.extend(
        step.get("with", {}).get("role", "")
        for step in job.get("steps", [])
        if step.get("uses", "").startswith("hashicorp/vault-action@")
    )
    assert any(role == "github-actions-platform-ops-toolkit-uat-observability" for role in roles), (
        f"{job_name} must use the workflow-scoped Observability Vault role"
    )

role_path = root / "scripts/vault/roles/github-actions-platform-ops-toolkit-uat-observability.json"
role = json.loads(role_path.read_text())
assert role["bound_claims"] == {
    "repository": "ai-workspace-infra/platform-ops-toolkit",
    "job_workflow_ref": "ai-workspace-infra/platform-ops-toolkit/.github/workflows/observability-server.yml@refs/heads/main",
    "ref": "refs/heads/main",
    "environment": "uat",
}
assert role["token_policies"] == ["github-actions-platform-ops-toolkit-uat-observability"]
assert role["token_no_default_policy"] is True
policy = (root / "scripts/vault/policies/github-actions-platform-ops-toolkit-uat-observability.hcl").read_text()
assert 'path "kv/data/CICD"' in policy and 'capabilities = ["read"]' in policy
assert "*" not in policy

shared_job = workflow["jobs"]["deploy_shared_target"]
assert shared_job["environment"] == "prod"
assert shared_job["permissions"]["id-token"] == "write"
assert "gcloud compute os-login ssh-keys add" in str(shared_job)
assert "gcloud compute firewall-rules delete" in str(shared_job)
assert "target_platform == 'shared-gcp'" in str(shared_job.get("if", ""))

shared_role_path = root / "scripts/vault/roles/github-actions-platform-ops-toolkit-shared-gcp-service-open-platform-shared.json"
shared_role = json.loads(shared_role_path.read_text())
assert shared_role["bound_claims"] == {
    "repository": "ai-workspace-infra/platform-ops-toolkit",
    "environment": "prod",
    "job_workflow_ref": "ai-workspace-infra/platform-ops-toolkit/.github/workflows/observability-server.yml@refs/heads/main",
    "ref": "refs/heads/main",
}
assert shared_role["token_policies"] == ["github-actions-platform-ops-toolkit-shared-gcp-service-open-platform-shared"]
shared_policy = (root / "scripts/vault/policies/github-actions-platform-ops-toolkit-shared-gcp-service-open-platform-shared.hcl").read_text()
assert 'kv/data/shared/platform/oidc/open-platform-shared' in shared_policy
assert "CICD" not in shared_policy and "*" not in shared_policy

print("observability_oidc_permissions_contract: PASS")
