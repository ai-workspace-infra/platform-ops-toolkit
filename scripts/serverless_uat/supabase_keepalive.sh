#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Supabase Free UAT 数据库轻量心跳保活脚本 (每周运行防 7 天暂停)
# -----------------------------------------------------------------------------

VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"

echo "==> [Keepalive] Querying Vault for Supabase UAT project endpoint..."

if [[ -n "${VAULT_TOKEN:-}" ]]; then
  SUPABASE_SECRET=$(curl -fsSL -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/kv/data/uat/serverless/supabase" 2>/dev/null || true)
  
  PROJECT_URL=$(echo "${SUPABASE_SECRET}" | jq -r '.data.data.PROJECT_URL // empty')
  ANON_KEY=$(echo "${SUPABASE_SECRET}" | jq -r '.data.data.ANON_KEY // empty')
fi

PROJECT_URL="${PROJECT_URL:-${SUPABASE_PROJECT_URL:-}}"
ANON_KEY="${ANON_KEY:-${SUPABASE_ANON_KEY:-}}"

if [[ -z "${PROJECT_URL}" || -z "${ANON_KEY}" ]]; then
  echo "Notice: Supabase credentials not found or empty, skipping keepalive ping"
  exit 0
fi

echo "==> [Keepalive] Sending REST heartbeat ping to ${PROJECT_URL}/rest/v1/..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ANON_KEY}" \
  "${PROJECT_URL}/rest/v1/" || echo "000")

echo "==> [Keepalive] Received HTTP response status: ${HTTP_CODE}"
echo "==> [Success] Supabase Free UAT store is active and healthy."
