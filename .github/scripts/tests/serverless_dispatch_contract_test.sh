#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
validate_script="${repo_root}/.github/scripts/serverless/validate_dispatch_inputs.sh"

run_case() {
  local operation="$1"
  local tag_ref="${2:-}"
  OPERATION="${operation}" \
  TARGET_DOMAINS=all \
  CLOUD_PROVIDER=vultr-vps \
  VAULT_ENV_PATH=uat \
  TAG_REF="${tag_ref}" \
  DEPLOY_CLOUDFLARE=true \
  DEPLOY_CLOUD_RUN=true \
  SERVERLESS_DNS_MODE=none \
  "${validate_script}"
}

run_case plan
run_case init-schema
run_case migrate
run_case deploy daily-build-2026.08.17-r1
run_case deploy+migrate daily-build-2026.08.17-r1
run_case destroy

if OPERATION=deploy TARGET_DOMAINS=all CLOUD_PROVIDER=vultr-vps VAULT_ENV_PATH=uat TAG_REF='' DEPLOY_CLOUDFLARE=true DEPLOY_CLOUD_RUN=true "${validate_script}" >/dev/null 2>&1; then
  echo "deploy without tag_ref unexpectedly succeeded" >&2
  exit 1
fi

if OPERATION=saas TARGET_DOMAINS=all CLOUD_PROVIDER=vultr-vps VAULT_ENV_PATH=uat TAG_REF='' DEPLOY_CLOUDFLARE=true DEPLOY_CLOUD_RUN=true "${validate_script}" >/dev/null 2>&1; then
  echo "legacy saas operation unexpectedly succeeded" >&2
  exit 1
fi

if OPERATION=deploy TARGET_DOMAINS=all CLOUD_PROVIDER=vultr-vps VAULT_ENV_PATH=uat TAG_REF=daily-build-2026.08.17-r1 DEPLOY_CLOUDFLARE=false DEPLOY_CLOUD_RUN=false "${validate_script}" >/dev/null 2>&1; then
  echo "deploy without an application target unexpectedly succeeded" >&2
  exit 1
fi

SERVERLESS_DNS_MODE=uat-records \
OPERATION=deploy \
TARGET_DOMAINS=web-saas \
CLOUD_PROVIDER=vultr-vps \
VAULT_ENV_PATH=uat \
TAG_REF=daily-build-2026.08.17-r1 \
DEPLOY_CLOUDFLARE=true \
DEPLOY_CLOUD_RUN=true \
"${validate_script}" >/dev/null

if SERVERLESS_DNS_MODE=uat-records OPERATION=migrate TARGET_DOMAINS=all CLOUD_PROVIDER=vultr-vps VAULT_ENV_PATH=uat DEPLOY_CLOUDFLARE=true DEPLOY_CLOUD_RUN=true "${validate_script}" >/dev/null 2>&1; then
  echo "uat-records unexpectedly accepted for migrate" >&2
  exit 1
fi

if SERVERLESS_DNS_MODE=uat-records OPERATION=deploy TARGET_DOMAINS=all CLOUD_PROVIDER=vultr-vps VAULT_ENV_PATH=uat TAG_REF=daily-build-2026.08.17-r1 DEPLOY_CLOUDFLARE=false DEPLOY_CLOUD_RUN=true "${validate_script}" >/dev/null 2>&1; then
  echo "uat-records unexpectedly accepted without Cloudflare deployment" >&2
  exit 1
fi

SERVERLESS_DNS_MODE=prod-cutover \
OPERATION=deploy \
TARGET_DOMAINS=all \
CLOUD_PROVIDER=vultr-vps \
VAULT_ENV_PATH=prod \
TAG_REF=v2026.08.17 \
DEPLOY_CLOUDFLARE=true \
DEPLOY_CLOUD_RUN=true \
"${validate_script}" >/dev/null

if SERVERLESS_DNS_MODE=prod-cutover OPERATION=deploy TARGET_DOMAINS=all CLOUD_PROVIDER=vultr-vps VAULT_ENV_PATH=uat TAG_REF=daily-build-2026.08.17-r1 DEPLOY_CLOUDFLARE=true DEPLOY_CLOUD_RUN=true "${validate_script}" >/dev/null 2>&1; then
  echo "prod-cutover unexpectedly accepted for uat" >&2
  exit 1
fi

OPERATION=plan TARGET_DOMAINS=web-saas CLOUD_PROVIDER=vultr-vps VAULT_ENV_PATH=uat DEPLOY_CLOUDFLARE=true DEPLOY_CLOUD_RUN=true "${validate_script}" >/dev/null

if OPERATION=plan TARGET_DOMAINS=agent-proxy CLOUD_PROVIDER=vultr-vps VAULT_ENV_PATH=uat DEPLOY_CLOUDFLARE=true DEPLOY_CLOUD_RUN=true "${validate_script}" >/dev/null 2>&1; then
  echo "unwired serverless domain unexpectedly succeeded" >&2
  exit 1
fi

if OPERATION=plan TARGET_DOMAINS=all CLOUD_PROVIDER=gcp-cloud VAULT_ENV_PATH=uat DEPLOY_CLOUDFLARE=true DEPLOY_CLOUD_RUN=true "${validate_script}" >/dev/null 2>&1; then
  echo "unwired environment replica provider unexpectedly succeeded" >&2
  exit 1
fi

echo "serverless_dispatch_contract_test: PASS"
