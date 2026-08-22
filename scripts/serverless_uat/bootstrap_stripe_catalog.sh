#!/usr/bin/env bash
set -euo pipefail

# Initializes the paid Accounts catalog for a new serverless environment.
#
# The workflow authenticates to Vault via GitHub OIDC and exports VAULT_TOKEN.
# This script reads the target environment's Stripe key and the bootstrap
# administrator password at runtime. Neither value is written to disk or logs.

: "${ACCOUNTS_DIR:?ACCOUNTS_DIR must point to an accounts checkout}"
: "${ACCOUNTS_BASE_URL:?ACCOUNTS_BASE_URL is required}"
: "${VAULT_ENV_PATH:?VAULT_ENV_PATH is required}"
: "${VAULT_TOKEN:?VAULT_TOKEN is required (GitHub OIDC Vault token)}"

VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
VAULT_ADDR="${VAULT_ADDR%/}"
ACCOUNTS_BASE_URL="${ACCOUNTS_BASE_URL%/}"
DOMAIN_BASE="${DOMAIN_BASE:-onwalk.net}"
CATALOG_SEED="${ACCOUNTS_DIR}/scripts/seed-billing-plans.sql"
SYNC_SCRIPT="${ACCOUNTS_DIR}/scripts/stripe-sync-catalog.sh"
SKIP_DATABASE_SEED="${SKIP_DATABASE_SEED:-false}"

command -v vault >/dev/null || { echo "vault CLI is required" >&2; exit 2; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
if [[ "${SKIP_DATABASE_SEED}" != "true" ]]; then
  command -v psql >/dev/null || { echo "psql is required" >&2; exit 2; }
  test -f "${CATALOG_SEED}" || { echo "billing catalog seed is missing: ${CATALOG_SEED}" >&2; exit 2; }
fi
test -x "${SYNC_SCRIPT}" || { echo "Stripe catalog sync script is missing or not executable: ${SYNC_SCRIPT}" >&2; exit 2; }

case "${VAULT_ENV_PATH}" in
  sit|uat|prod) ;;
  *) echo "VAULT_ENV_PATH must be sit, uat, or prod" >&2; exit 2 ;;
esac

read_vault_key() {
  local path="$1"
  local key="$2"
  vault kv get -format=json "${path}" | jq -er --arg key "${key}" '.data.data[$key] // empty'
}

wait_for_accounts() {
  local attempt status
  for attempt in $(seq 1 30); do
    status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
      --max-time 15 "${ACCOUNTS_BASE_URL}/api/billing/plans" || true)"
    if [[ "${status}" == "200" ]]; then
      return 0
    fi
    echo "Waiting for Accounts catalog API (${attempt}/30, HTTP ${status:-unreachable})..." >&2
    sleep 5
  done
  echo "Accounts catalog API did not become ready: ${ACCOUNTS_BASE_URL}" >&2
  return 1
}

echo "== Stripe catalog bootstrap: env=${VAULT_ENV_PATH}, accounts=${ACCOUNTS_BASE_URL} =="

if [[ "${SKIP_DATABASE_SEED}" == "true" ]]; then
  echo "Database seed is owned by the self-hosted schema initializer; skipping it here."
else
  supabase_path="kv/${VAULT_ENV_PATH}/serverless/supabase"
  database_uri="$(read_vault_key "${supabase_path}" "SUPABASE_CONNECT_URI" 2>/dev/null || true)"
  if [[ -z "${database_uri}" ]]; then
    database_uri="$(read_vault_key "${supabase_path}" "DATABASE_SESSION_POOLER_URL" 2>/dev/null || true)"
  fi
  if [[ -z "${database_uri}" ]]; then
    database_uri="$(read_vault_key "${supabase_path}" "DATABASE_DIRECT_URL")"
  fi

  if [[ "$(psql "${database_uri}" -Atqc "SELECT to_regclass('public.billing_plans') IS NOT NULL")" != "t" ]]; then
    echo "billing_plans is absent; run the Accounts schema initialization before Stripe bootstrap" >&2
    exit 1
  fi

  if [[ "$(psql "${database_uri}" -Atqc "SELECT EXISTS (SELECT 1 FROM public.billing_plans WHERE plan_id = 'PRO-MONTHLY')")" != "t" ]]; then
    echo "Seeding the initial paid billing catalog..."
    psql "${database_uri}" -v ON_ERROR_STOP=1 -f "${CATALOG_SEED}" >/dev/null
  else
    echo "Paid billing catalog already exists; seed skipped."
  fi
fi

wait_for_accounts

stripe_secret_key="$(read_vault_key "kv/${VAULT_ENV_PATH}/billing-service" "STRIPE_SECRET_KEY")"
root_email="$(read_vault_key "kv/CICD" "ROOT_BOOTSTRAP_EMAIL" 2>/dev/null || true)"
root_email="${root_email:-admin@svc.plus}"
root_password="$(read_vault_key "kv/CICD" "ROOT_BOOTSTRAP_PASSWORD")"

login_body="$(mktemp)"
trap 'rm -f "${login_body}"' EXIT
login_status="$(curl --silent --show-error --output "${login_body}" --write-out '%{http_code}' \
  --max-time 20 --request POST "${ACCOUNTS_BASE_URL}/api/auth/login" \
  --header 'Content-Type: application/json' \
  --data "$(jq -n --arg identifier "${root_email}" --arg password "${root_password}" '{identifier: $identifier, password: $password}')" || true)"
if [[ "${login_status}" != "200" ]]; then
  echo "Accounts bootstrap administrator login failed (HTTP ${login_status:-unreachable})." >&2
  exit 1
fi
accounts_admin_token="$(jq -er '.token // empty' < "${login_body}")"

echo "Synchronizing Stripe Products, Prices, webhook, and catalog snapshots..."
STRIPE_SECRET_KEY="${stripe_secret_key}" \
ACCOUNTS_ADMIN_TOKEN="${accounts_admin_token}" \
ACCOUNTS_BASE_URL="${ACCOUNTS_BASE_URL}" \
"${SYNC_SCRIPT}" --env "${VAULT_ENV_PATH}" --domain-base "${DOMAIN_BASE}" --write-catalog

echo "Stripe catalog bootstrap completed for ${VAULT_ENV_PATH}."
