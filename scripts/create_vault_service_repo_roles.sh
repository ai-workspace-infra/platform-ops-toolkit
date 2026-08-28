#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Vault Authentication & Policy Split Initialization (Consolidated Entrypoint)
#
# Requirements:
# 1. Run this script from a terminal with access to Vault (e.g. https://vault.svc.plus).
# 2. Vault must be initialized and unsealed.
# 3. Export VAULT_ADDR and VAULT_TOKEN (with admin privileges).
#
# -----------------------------------------------------------------------------
# Summary of Security & Governance Rules:
#
# 1. Platform-Ops Toolkit & Playbooks:
#    - user_claim is set to 'sub' (workload identity: repo + ref + workflow).
#    - job_workflow_ref is pinned to the explicit workflow allowlist.
#    - Token policies provide strict tier-based isolation for sit, uat, and prod.
#    - Token type is batch (1h TTL, no default policy).
#
# 2. Business Service Repositories (accounts, billing-service, console, content-service, docs, postgresql):
#    - Dedicated github-actions-<service> policy giving read-only access to kv/data/CICD (GHCR push credentials).
#    - Business CI workflows do not inherit platform policies or environment-level secrets.
# =============================================================================

export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"

if [ -z "${VAULT_TOKEN:-}" ] && ! vault token lookup >/dev/null 2>&1; then
  echo "Error: no authenticated Vault CLI session is available." >&2
  echo "  export VAULT_ADDR=https://vault.svc.plus" >&2
  echo "  export VAULT_TOKEN=hvs.xxx   (admin token, do NOT commit it)" >&2
  exit 1
fi

REPO="ai-workspace-infra/platform-ops-toolkit"
PLAYBOOKS_REPO="ai-workspace-infra/playbooks"
TOKEN_TTL="1h"

# -----------------------------------------------------------------------------
# Workflow Allowlists for Platform-Ops & Playbooks
# -----------------------------------------------------------------------------
WF_PREFIX="${REPO}/.github/workflows"
read -r -d '' ALLOWED_WORKFLOWS <<EOF || true
    "${WF_PREFIX}/selfhost-orchestrator.yml@*",
    "${WF_PREFIX}/daily-main-snapshot.yaml@*",
    "${WF_PREFIX}/resize-instance.yaml@*",
    "${WF_PREFIX}/deploy-action-runner-iac.yaml@*",
    "${WF_PREFIX}/iac-pipeline-multi-cloud-account-matrix.yaml@*",
    "${WF_PREFIX}/iac-pipeline-multi-cloud-resources-matrix.yaml@*",
    "${WF_PREFIX}/iac-pipeline-multi-cloud-landingzone-baseline.yaml@*",
    "${WF_PREFIX}/cron-rotate-domain-tls-certs.yaml@*",
    "${WF_PREFIX}/data-migration.yaml@*",
    "${WF_PREFIX}/k6-performance-test.yaml@*",
    "${WF_PREFIX}/uat-serverless-orchestrator.yml@*",
    "${WF_PREFIX}/serverless-orchestrator.yml@*",
    "${WF_PREFIX}/hybrid-orchestrator.yml@*"
EOF

PLAYBOOKS_WF_PREFIX="${PLAYBOOKS_REPO}/.github/workflows"
read -r -d '' PLAYBOOKS_ALLOWED_WORKFLOWS <<EOF || true
    "${PLAYBOOKS_WF_PREFIX}/web-saas-domain-cd.yaml@*",
    "${PLAYBOOKS_WF_PREFIX}/ai-workspace-domain-cd.yaml@*",
    "${PLAYBOOKS_WF_PREFIX}/agent-proxy-domain-cd.yaml@*",
    "${PLAYBOOKS_WF_PREFIX}/open-platform-domain-cd.yaml@*",
    "${PLAYBOOKS_WF_PREFIX}/domain-cd.yaml@*"
EOF

# -----------------------------------------------------------------------------
# Platform-Ops Tier Policies (Common Read + Domain Certs + Env Credentials)
# -----------------------------------------------------------------------------
emit_common_read_paths() {
  cat <<'EOF'
path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/data/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
path "kv/data/CICD/observability" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["list", "read"]
}
path "kv/metadata/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
path "kv/data/openclaw" {
  capabilities = ["read"]
}
path "kv/data/action-runner" {
  capabilities = ["read"]
}
path "kv/metadata/action-runner" {
  capabilities = ["list", "read"]
}
EOF
}

emit_domain_cert_paths() {
  cat <<'EOF'
path "kv/data/CICD/domains/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "kv/metadata/CICD/domains/*" {
  capabilities = ["list", "read"]
}
EOF
}

emit_base_credential_paths() {
  local env="$1"
  cat <<EOF
path "kv/data/CICD/${env}" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/${env}" {
  capabilities = ["list", "read"]
}
EOF
}

emit_env_policy() {
  local env="$1"

  emit_common_read_paths
  emit_domain_cert_paths
  emit_base_credential_paths "${env}"

  if [ "${env}" != "sit" ]; then
    cat <<'EOF'
path "kv/data/WEB_SAAS" {
  capabilities = ["read"]
}
path "kv/metadata/WEB_SAAS" {
  capabilities = ["list", "read"]
}
EOF
  fi

  if [ "${env}" = "prod" ]; then
    cat <<EOF
path "kv/data/${env}/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "kv/metadata/${env}/*" {
  capabilities = ["list", "read"]
}
EOF
  else
    cat <<EOF
path "kv/data/${env}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "kv/metadata/${env}/*" {
  capabilities = ["list", "read", "delete"]
}
EOF
  fi
}

echo "=== Provisioning Platform-Ops Policies ==="
for env in dev sit uat prod; do
  echo "  Writing policy github-actions-platform-ops-toolkit-${env}..."
  emit_env_policy "${env}" | vault policy write "github-actions-platform-ops-toolkit-${env}" -
done

# -----------------------------------------------------------------------------
# Platform-Ops & Playbooks Roles
# -----------------------------------------------------------------------------
write_role() {
  local suffix="$1" policy="$2" ref_claim="$3"
  vault write "auth/jwt/role/github-actions-platform-ops-toolkit-${suffix}" - <<EOF
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["vault"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository": "${REPO}",
    "job_workflow_ref": [
${ALLOWED_WORKFLOWS}
    ],
    "ref": ${ref_claim}
  },
  "token_policies": ["${policy}"],
  "token_no_default_policy": true,
  "token_type": "batch",
  "token_ttl": "${TOKEN_TTL}",
  "token_max_ttl": "${TOKEN_TTL}"
}
EOF
}

# `main` can initiate a release but is never the release artifact: Daily Main
# Snapshot re-tags an already verified immutable source as a new v* tag. This
# role is deliberately pinned to that one workflow on protected main, so the
# normal production role stays restricted to release tags / release branches.
write_daily_snapshot_prod_release_role() {
  vault write "auth/jwt/role/github-actions-platform-ops-toolkit-prod-release" - <<EOF
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["vault"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository": "${REPO}",
    "job_workflow_ref": "${WF_PREFIX}/daily-main-snapshot.yaml@*",
    "ref": "refs/heads/main"
  },
  "token_policies": ["github-actions-platform-ops-toolkit-prod"],
  "token_no_default_policy": true,
  "token_type": "batch",
  "token_ttl": "${TOKEN_TTL}",
  "token_max_ttl": "${TOKEN_TTL}"
}
EOF
}

write_playbooks_role() {
  local suffix="$1" policy="$2" ref_claim="$3"
  vault write "auth/jwt/role/github-actions-playbooks-${suffix}" - <<EOF
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["vault"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository": "${REPO}",
    "job_workflow_ref": [
${PLAYBOOKS_ALLOWED_WORKFLOWS}
    ],
    "ref": ${ref_claim}
  },
  "token_policies": ["${policy}"],
  "token_no_default_policy": true,
  "token_type": "batch",
  "token_ttl": "${TOKEN_TTL}",
  "token_max_ttl": "${TOKEN_TTL}"
}
EOF
}

echo "=== Provisioning Platform-Ops & Playbooks Roles ==="
echo "  Creating SIT role..."
write_role sit github-actions-platform-ops-toolkit-sit '["refs/pull/*/merge", "refs/heads/*"]'
echo "  Creating DEV role..."
write_role dev github-actions-platform-ops-toolkit-dev '["refs/heads/main", "refs/heads/dev/*", "refs/heads/feature/*", "refs/pull/*/merge"]'
echo "  Creating UAT role..."
write_role uat github-actions-platform-ops-toolkit-uat '["refs/heads/main", "refs/heads/release/*", "refs/heads/bugfix/*", "refs/heads/daily-build-*", "refs/tags/daily-build-*"]'
echo "  Creating PROD role..."
write_role prod github-actions-platform-ops-toolkit-prod '["refs/tags/v*", "refs/heads/release/v*"]'
echo "  Creating PROD release-authoring role..."
write_daily_snapshot_prod_release_role

echo "  Creating Playbooks SIT role..."
write_playbooks_role sit github-actions-platform-ops-toolkit-sit '["refs/pull/*/merge", "refs/heads/*"]'
echo "  Creating Playbooks UAT role..."
write_playbooks_role uat github-actions-platform-ops-toolkit-uat '["refs/heads/main", "refs/heads/release/*", "refs/heads/bugfix/*", "refs/heads/daily-build-*", "refs/tags/daily-build-*"]'
echo "  Creating Playbooks PROD role..."
write_playbooks_role prod github-actions-platform-ops-toolkit-prod '["refs/tags/v*", "refs/heads/release/v*"]'

# -----------------------------------------------------------------------------
# Business Service Repository Roles & Policies
# -----------------------------------------------------------------------------
write_service_policy() {
  local service="$1"
  echo "  Creating policy github-actions-${service}..."
  vault policy write "github-actions-${service}" - <<'EOF'
path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["list", "read"]
}
EOF
}

write_service_role() {
  local service="$1" suffix="$2" ref_claim="$3" repo="$4"
  local workflow_glob="${5:-${repo}/.github/workflows/*pipeline.ym*@*}"
  echo "  Creating role github-actions-${service}-${suffix} <- ${repo}"
  vault write "auth/jwt/role/github-actions-${service}-${suffix}" - <<EOF
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["vault"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository": "${repo}",
    "job_workflow_ref": "${workflow_glob}",
    "ref": ${ref_claim}
  },
  "token_policies": ["github-actions-${service}"],
  "token_no_default_policy": true,
  "token_type": "batch",
  "token_ttl": "${TOKEN_TTL}",
  "token_max_ttl": "${TOKEN_TTL}"
}
EOF
}

process_service_repo() {
  local service="$1" repo="$2" workflow="${3:-}"
  echo "=== Business Service: ${service} (${repo}) ==="
  write_service_policy "${service}"

  write_service_role "${service}" sit \
    '["refs/pull/*/merge", "refs/heads/*", "refs/tags/sit-*"]' \
    "${repo}" "${workflow}"

  write_service_role "${service}" uat \
    '["refs/heads/main", "refs/heads/release/*", "refs/heads/daily-build-*", "refs/tags/uat-*", "refs/tags/daily-build-*"]' \
    "${repo}" "${workflow}"

  write_service_role "${service}" prod \
    '["refs/tags/v*", "refs/heads/release/v*"]' \
    "${repo}" "${workflow}"
}

process_gitops_service_repo() {
  local repo="ai-workspace-infra/gitops"
  local workflow="${repo}/.github/workflows/validate-release-pr.yml@*"
  echo "=== Deployment Consumer: gitops (${repo}) ==="
  write_service_policy gitops
  write_service_role gitops sit '"refs/pull/*/merge"' "${repo}" "${workflow}"
  write_service_role gitops uat '"refs/heads/main"' "${repo}" "${workflow}"
  write_service_role gitops prod '["refs/tags/v*", "refs/heads/release/v*"]' "${repo}" "${workflow}"
}

process_artifacts_service_repo() {
  local repo="ai-workspace-infra/artifacts"
  local workflow="${repo}/.github/workflows/*@*"
  echo "=== Infrastructure Artifacts: artifacts (${repo}) ==="
  echo "  Creating policy github-actions-artifacts..."
  vault policy write github-actions-artifacts - <<'EOF'
path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/data/CICD/*" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["list", "read"]
}
path "kv/metadata/CICD/*" {
  capabilities = ["list", "read"]
}
EOF

  write_service_role artifacts sit \
    '["refs/pull/*/merge", "refs/heads/*", "refs/tags/sit-*"]' \
    "${repo}" "${workflow}"

  write_service_role artifacts uat \
    '["refs/heads/main", "refs/heads/feature/*", "refs/heads/daily-build-*", "refs/tags/uat-*", "refs/tags/daily-build-*"]' \
    "${repo}" "${workflow}"

  write_service_role artifacts prod \
    '["refs/tags/v*", "refs/heads/release/v*"]' \
    "${repo}" "${workflow}"
}

process_service_repo accounts         ai-workspace-services/accounts
process_service_repo billing-service  ai-workspace-services/billing-service
process_service_repo console          ai-workspace-services/portal
process_service_repo content-service  ai-workspace-services/content-service
process_service_repo docs             ai-workspace-services/docs
process_service_repo postgresql       ai-workspace-services/postgresql.svc.plus
process_artifacts_service_repo
process_gitops_service_repo

# -----------------------------------------------------------------------------
# Dead Role Cleanup
# -----------------------------------------------------------------------------
echo "=== Cleaning Up Deprecated Roles ==="
vault delete auth/jwt/role/github-actions-platform-ops-toolkit-prod-tags 2>/dev/null \
  || echo "  (github-actions-platform-ops-toolkit-prod-tags not present, skipped)"

echo
echo "========================================================================="
echo " Vault Authentication & Policy Consolidation Completed Successfully."
echo "========================================================================="
