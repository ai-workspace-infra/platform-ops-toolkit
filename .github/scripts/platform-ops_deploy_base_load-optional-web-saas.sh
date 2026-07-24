#!/usr/bin/env bash
# 读取 web-saas 的**可选**密钥, 缺失即视为空, 导出到 GITHUB_ENV。
#
# 为什么不放进 vault-action 那步一起读: hashicorp/vault-action@v4 的
# ignoreNotFound 只在整个 KV 路径 404 时生效; 路径存在而某个 selector(键)
# 缺失时, 它照样以 "No match data was found" 硬失败。所以"路径在、键可缺"
# 这种真正可选的语义, vault-action 表达不了, 只能自己读整份 secret 再按键
# 取值、缺则空。必需键仍留在 vault-action 里硬读(缺了就该失败)。
set -euo pipefail

: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_TOKEN:?VAULT_TOKEN is required}"
: "${VAULT_KV_WEB_SAAS:?VAULT_KV_WEB_SAAS is required (e.g. kv/data/WEB_SAAS)}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

OPTIONAL_KEYS=(
  OAUTH_GITHUB_CLIENT_ID
  OAUTH_GITHUB_CLIENT_SECRET
  OAUTH_GOOGLE_CLIENT_ID
  OAUTH_GOOGLE_CLIENT_SECRET
  INTERNAL_SERVICE_TOKEN
)

body="$(mktemp)"
trap 'rm -f "${body}"' EXIT
status="$(curl -s -o "${body}" -w '%{http_code}' \
  -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/${VAULT_KV_WEB_SAAS}")"

# 404 = 整份 WEB_SAAS 不存在。可选键全部按空处理, 不失败 —— 这正是"可选"。
# 其它非 2xx 才是真异常(权限/服务端), 要报出来。
if [[ "${status}" != "200" && "${status}" != "404" ]]; then
  echo "::error::Reading ${VAULT_KV_WEB_SAAS} returned HTTP ${status}." >&2
  head -c 300 "${body}" >&2
  exit 1
fi

for key in "${OPTIONAL_KEYS[@]}"; do
  if [[ "${status}" == "200" ]]; then
    val="$(jq -r --arg k "${key}" '.data.data[$k] // ""' < "${body}")"
  else
    val=""
  fi
  # 非空即 mask, 避免落进日志; 空值不必 mask(mask 空串会把后续所有输出
  # 里的空匹配都打码, 反而制造噪音)。
  [[ -n "${val}" ]] && echo "::add-mask::${val}"
  echo "${key}=${val}" >> "${GITHUB_ENV}"
done

echo "Loaded ${#OPTIONAL_KEYS[@]} optional web-saas key(s) from ${VAULT_KV_WEB_SAAS} (missing -> empty)."
