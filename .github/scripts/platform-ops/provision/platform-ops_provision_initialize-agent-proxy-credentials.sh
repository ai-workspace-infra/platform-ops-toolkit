#!/bin/bash
URL="${VAULT_ADDR}/v1/kv/data/${VAULT_ENV_PATH}/agent-proxy"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Vault-Token: $VAULT_TOKEN" "$URL")
if [ "$STATUS" = "404" ]; then
  echo "Initializing agent proxy credentials..."
  PAYLOAD=$(jq -n \
    --arg xray_uuid "$(uuidgen)" \
    '{data: {xray_uuid: $xray_uuid}}')
  curl -sS -X POST -H "X-Vault-Token: $VAULT_TOKEN" -H "Content-Type: application/json" -d "$PAYLOAD" "$URL"
else
  echo "Credentials already exist (Status: $STATUS). Skipping."
fi
