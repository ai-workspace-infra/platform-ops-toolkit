#!/usr/bin/env bash
# 读取 web-saas 与计费域的**可选**密钥, 缺失即视为空, 导出到 GITHUB_ENV。
#
# 为什么不放进 vault-action 那步一起读: hashicorp/vault-action@v4 的
# ignoreNotFound 只在整个 KV 路径 404 时生效; 路径存在而某个 selector(键)
# 缺失时, 它照样以 "No match data was found" 硬失败。所以"路径在、键可缺"
# 这种真正可选的语义, vault-action 表达不了, 只能自己读整份 secret 再按键
# 取值、缺则空。必需键仍留在 vault-action 里硬读(缺了就该失败)。
#
# 认证自己走 JWT role, 不依赖上一步导出的 VAULT_TOKEN: 静态 token 只是
# 别处场景下的可选 fallback, 这条流水线的默认认证方式是 GitHub OIDC ->
# Vault JWT role(与 vault-action 内部做的事一样), 不应该在这里引入一条
# "依赖前一步是否恰好导出了 token"的隐式耦合。
set -euo pipefail

: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_ROLE:?VAULT_ROLE is required}"
: "${VAULT_KV_WEB_SAAS:?VAULT_KV_WEB_SAAS is required (e.g. kv/data/WEB_SAAS)}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?ACTIONS_ID_TOKEN_REQUEST_URL is required (needs id-token: write)}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?ACTIONS_ID_TOKEN_REQUEST_TOKEN is required (needs id-token: write)}"

OPTIONAL_KEYS=(
  OAUTH_GITHUB_CLIENT_ID
  OAUTH_GITHUB_CLIENT_SECRET
  OAUTH_GOOGLE_CLIENT_ID
  OAUTH_GOOGLE_CLIENT_SECRET
  INTERNAL_SERVICE_TOKEN
  EXPORTER_SOURCES_JSON
)

# 1. 用 GitHub 的 OIDC id-token 换 Vault JWT 登录用的 JWT。
oidc="$(curl -sS --retry 3 \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=vault")"
gh_jwt="$(jq -r '.value // empty' <<<"${oidc}")"
[[ -n "${gh_jwt}" ]] || {
  echo "::error::Failed to obtain a GitHub OIDC token for audience=vault." >&2
  exit 1
}

# 2. 用这个 JWT 走 role 登录 Vault, 拿一次性 client token。
login_body="$(mktemp)"
trap 'rm -f "${login_body}"' EXIT
login_status="$(curl -sS -o "${login_body}" -w '%{http_code}' \
  -X POST -H "Content-Type: application/json" \
  -d "$(jq -n --arg role "${VAULT_ROLE}" --arg jwt "${gh_jwt}" '{role: $role, jwt: $jwt}')" \
  "${VAULT_ADDR}/v1/auth/jwt/login")"
[[ "${login_status}" == "200" ]] || {
  echo "::error::Vault JWT login failed (HTTP ${login_status}) for role ${VAULT_ROLE}." >&2
  head -c 300 "${login_body}" >&2
  exit 1
}
vault_token="$(jq -r '.auth.client_token // empty' < "${login_body}")"
[[ -n "${vault_token}" ]] || {
  echo "::error::Vault JWT login response had no client_token." >&2
  exit 1
}

# 3. 用这个 token 读整份 WEB_SAAS, 按键取值、缺则空。
body="$(mktemp)"
status="$(curl -sS -o "${body}" -w '%{http_code}' \
  -H "X-Vault-Token: ${vault_token}" "${VAULT_ADDR}/v1/${VAULT_KV_WEB_SAAS}")"

# 404 = 整份 WEB_SAAS 不存在。可选键全部按空处理, 不失败 —— 这正是"可选"。
# 其它非 2xx 才是真异常(权限/服务端), 要报出来。
if [[ "${status}" != "200" && "${status}" != "404" ]]; then
  echo "::error::Reading ${VAULT_KV_WEB_SAAS} returned HTTP ${status}." >&2
  head -c 300 "${body}" >&2
  rm -f "${body}"
  exit 1
fi

for key in "${OPTIONAL_KEYS[@]}"; do
  if [[ "${status}" == "200" ]]; then
    val="$(jq -r --arg k "${key}" '.data.data[$k] // ""' < "${body}")"
  else
    val=""
  fi
  if [[ "${key}" == "EXPORTER_SOURCES_JSON" && -z "${val}" && "${DEPLOY_ENV:-}" == "uat" ]]; then
    exporter_host="agent-proxy.${TARGET_DOMAIN_BASE:-onwalk.net}"
    val="$(jq -cn --arg host "${exporter_host}" '[
      {source_id: "xhttp-uat", base_url: ("https://" + $host + "/xray-exporter/xhttp")},
      {source_id: "tcp-uat", base_url: ("https://" + $host + "/xray-exporter/tcp")}
    ]')"
    echo "Using the UAT HTTPS Caddy exporter source list because WEB_SAAS/EXPORTER_SOURCES_JSON is not initialized yet."
  fi
  # 非空即 mask, 避免落进日志; 空值不必 mask(mask 空串会把后续所有输出
  # 里的空匹配都打码, 反而制造噪音)。
  [[ -n "${val}" ]] && echo "::add-mask::${val}"
  echo "${key}=${val}" >> "${GITHUB_ENV}"
done
rm -f "${body}"

echo "Loaded ${#OPTIONAL_KEYS[@]} optional web-saas key(s) from ${VAULT_KV_WEB_SAAS} (missing -> empty)."

# 4. 计费域密钥, 环境专属路径 kv/data/<env>/billing-service。
#
#    此前是共享的 kv/data/billing-service, 靠 SANDBOX_/PROD_ 键前缀区分两套
#    密钥。但 KV v2 的读权限是整份 secret 粒度, policy 无法只授其中几个键 ——
#    给 uat 角色开读权限就等于让它也能读到生产 Stripe 密钥, 而那把密钥能对
#    真实客户扣款和退款。拆成 kv/data/<env>/billing-service 之后, 既有的
#    kv/data/<env>/* 规则天然完成隔离, 键名也回归朴素(不再带环境前缀)。
#
#    仍然容忍 403/404: 目标环境的 secret 可能尚未创建。accounts 的 stripe
#    客户端在密钥为空时软性 disabled(见 accounts api/stripe.go enabled()),
#    拿不到密钥不该拖垮整个部署; secret 写入后自动生效, 无需改代码。
if [[ -n "${VAULT_KV_BILLING:-}" ]]; then
  billing_body="$(mktemp)"
  billing_status="$(curl -sS -o "${billing_body}" -w '%{http_code}' \
    -H "X-Vault-Token: ${vault_token}" "${VAULT_ADDR}/v1/${VAULT_KV_BILLING}")"

  if [[ "${billing_status}" != "200" && "${billing_status}" != "403" && "${billing_status}" != "404" ]]; then
    echo "::error::Reading ${VAULT_KV_BILLING} returned HTTP ${billing_status}." >&2
    head -c 300 "${billing_body}" >&2
    rm -f "${billing_body}"
    exit 1
  fi

  for key in STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET; do
    if [[ "${billing_status}" == "200" ]]; then
      val="$(jq -r --arg k "${key}" '.data.data[$k] // ""' < "${billing_body}")"
    else
      val=""
    fi
    [[ -n "${val}" ]] && echo "::add-mask::${val}"
    echo "${key}=${val}" >> "${GITHUB_ENV}"
  done
  rm -f "${billing_body}"

  if [[ "${billing_status}" == "200" ]]; then
    echo "Loaded Stripe keys from ${VAULT_KV_BILLING}."
  else
    echo "::warning::${VAULT_KV_BILLING} returned HTTP ${billing_status}; Stripe keys left empty, billing stays disabled for this deploy."
  fi
fi
