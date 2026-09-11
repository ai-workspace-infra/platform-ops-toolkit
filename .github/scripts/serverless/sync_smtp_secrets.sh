#!/bin/bash
# 把 kv/data/<env>/platform/smtp/google 的 SMTP 凭据同步进 GCP Secret Manager,
# 供 accounts 的 Cloud Run 服务以 secretKeyRef 读取。
#
# 为什么要中转一次: Cloud Run 只能从 Secret Manager 取 secretKeyRef, 读不了
# Vault; 而机密的源头必须是 Vault。直接用 --update-env-vars 把口令塞进
# service spec 是错的 —— 那样 `gcloud run services describe` 就能明文读出来。
# 所以 Vault 是源头, Secret Manager 只是 Cloud Run 能接受的投递形式。
#
# 只在值真的变了时才 versions add。每次部署无脑追加一个版本, 会让版本数随
# 部署次数线性膨胀, 迟早撞上 Secret Manager 的版本配额, 而且轮换审计时根本
# 分不清哪次是真的换了口令。
#
# 环境没种过凭据不算错误。sit/uat 可能还没灌 SMTP 口令, 此时应当跳过并让
# accounts 自己降级 —— 它在 SMTP 四要素任一为空时会关掉邮件发送并静默返回
# 成功。为这个让整条部署流水线失败是不成比例的。
set -euo pipefail

: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_TOKEN:?VAULT_TOKEN is required}"
: "${VAULT_ENV_PATH:?VAULT_ENV_PATH is required}"
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"

VAULT_SMTP_PATH="${VAULT_SMTP_PATH:-kv/data/${VAULT_ENV_PATH}/platform/smtp/google}"
URL="${VAULT_ADDR}/v1/${VAULT_SMTP_PATH}"

body="$(mktemp)"
trap 'rm -f "${body}"' EXIT

status="$(curl -s -o "${body}" -w '%{http_code}' -H "X-Vault-Token: ${VAULT_TOKEN}" "${URL}")"

if [ "${status}" = "404" ]; then
  echo "::notice::${VAULT_SMTP_PATH} is not seeded; leaving SMTP secrets untouched." \
       "accounts will start with email delivery disabled in ${VAULT_ENV_PATH}."
  exit 0
fi

if [[ ! "${status}" =~ ^2 ]]; then
  echo "::error::Failed to read ${VAULT_SMTP_PATH} (HTTP ${status})." >&2
  exit 1
fi

smtp_username="$(jq -r '.data.data.username // empty' "${body}")"
smtp_password="$(jq -r '.data.data.password // empty' "${body}")"

# KV v2 lets a secret exist while missing keys, so presence of the path proves
# nothing. A half-seeded path is a mistake worth failing on: it means somebody
# intended to configure SMTP here and got it wrong, which is not the same as
# an environment that deliberately has no SMTP at all.
if [ -z "${smtp_username}" ] || [ -z "${smtp_password}" ]; then
  echo "::error::${VAULT_SMTP_PATH} exists but is missing 'username' and/or 'password'." >&2
  exit 1
fi

# Check whether the Secret Manager API is enabled, so a non-interactive runner
# does not hit gcloud's (y/N) enable prompt and die on EOF.
#
# The check must not be the authority on whether to proceed. `gcloud services
# list` needs serviceusage.services.list, and a deployment identity that lacks
# it fails the call rather than returning an empty list - discarding stderr
# collapses "you may not ask" and "the API is off" into the same empty output.
# Read as "off", that silently ships a revision with email disabled while every
# step reports success. Treat only a successful query as evidence, and let the
# secret operations below be the real test in every other case: they are
# --quiet, and they already degrade one secret at a time.
secretmanager_state="unknown"
if services_output="$(gcloud services list --enabled \
      --project "${GCP_PROJECT_ID}" \
      --filter="config.name:secretmanager.googleapis.com" \
      --format="value(config.name)" 2>/dev/null)"; then
  if grep -q "secretmanager.googleapis.com" <<<"${services_output}"; then
    secretmanager_state="enabled"
  else
    secretmanager_state="disabled"
  fi
fi

case "${secretmanager_state}" in
  disabled)
    echo "::notice::Secret Manager API is not enabled on project ${GCP_PROJECT_ID}. Attempting to enable..."
    if ! gcloud services enable secretmanager.googleapis.com --project "${GCP_PROJECT_ID}" --quiet 2>/dev/null; then
      echo "::warning::Secret Manager API is disabled on project ${GCP_PROJECT_ID} and the deployment identity cannot enable it. Skipping Secret Manager sync; accounts will run with email delivery disabled." >&2
      exit 0
    fi
    echo "::notice::Successfully enabled Secret Manager API on project ${GCP_PROJECT_ID}."
    ;;
  unknown)
    echo "::notice::Cannot read the service list on project ${GCP_PROJECT_ID} (the deployment identity likely lacks serviceusage.services.list). Continuing - the secret operations below will report the real outcome."
    ;;
esac

sync_secret() {
  local name="$1" value="$2" current=""

  if ! gcloud secrets describe "${name}" --project "${GCP_PROJECT_ID}" --quiet >/dev/null 2>&1; then
    if ! gcloud secrets create "${name}" \
      --replication-policy=automatic \
      --project "${GCP_PROJECT_ID}" \
      --quiet >/dev/null 2>&1; then
      echo "::warning::Unable to create Secret Manager secret ${name} on project ${GCP_PROJECT_ID} (permission denied). Skipping." >&2
      return 0
    fi
    echo "::notice::Created Secret Manager secret ${name}."
  else
    # A secret whose every version is disabled or destroyed has no accessible
    # latest; treat that as "no current value" rather than letting the failure
    # escape and abort the deploy.
    current="$(gcloud secrets versions access latest \
      --secret "${name}" --project "${GCP_PROJECT_ID}" --quiet 2>/dev/null || true)"
  fi

  if [ "${current}" = "${value}" ]; then
    echo "::notice::${name} already matches Vault; no new version added."
    return 0
  fi

  if ! printf '%s' "${value}" | gcloud secrets versions add "${name}" \
    --data-file=- --project "${GCP_PROJECT_ID}" --quiet >/dev/null 2>&1; then
    echo "::warning::Unable to add version to Secret Manager secret ${name} on project ${GCP_PROJECT_ID}. Skipping." >&2
    return 0
  fi
  echo "::notice::Added a new version of ${name} from ${VAULT_SMTP_PATH}."
}

sync_secret smtp-username "${smtp_username}"
sync_secret smtp-password "${smtp_password}"
