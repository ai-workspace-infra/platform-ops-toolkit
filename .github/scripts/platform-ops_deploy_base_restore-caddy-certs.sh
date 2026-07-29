#!/usr/bin/env bash
set -euo pipefail

# 把上一次部署备份在 Vault 里的 caddy_data 恢复到主机, 让重建后的 caddy 一起来
# 就发现证书已在, 根本不去调 ACME。
#
# 不做这一步的后果: 主机重建会连 caddy_data 卷一起丢, 每次重建都重新签发,
# 撞上 Let's Encrypt "同一组域名 5 次/周" 的限流。2026-07-28 console-uat 就是
# 这么挂的(HTTP 429, retry after 20:38 UTC), 而且没有任何代码能修, 只能等窗口
# 过期。泛域名把每次重建的签发从 3 张降到 1 张, 但 5 次/周的上限还在 ——
# 真正让"反复重建"成立的是这一步。
#
# 恢复是 best-effort: 没有备份(第一次部署)不是错误, 照常让 caddy 自己去签。
# 但"有备份却恢复失败"必须失败, 否则就悄悄退回了每次重签的老路。

: "${MATRIX_HOST:?MATRIX_HOST is required}"
: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_TOKEN:?VAULT_TOKEN is required}"
: "${VAULT_CADDY_PATH:?VAULT_CADDY_PATH is required}"

ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20)
host="root@${MATRIX_HOST}"

# kv v2 的读路径要带 /data/, 而 VAULT_KV_BASE 传进来的已经是 kv/data/... 形式。
read_url="${VAULT_ADDR%/}/v1/${VAULT_CADDY_PATH}"

http_code="$(curl -sS -o /tmp/caddy-vault.json -w '%{http_code}' \
  -H "X-Vault-Token: ${VAULT_TOKEN}" "${read_url}" || echo 000)"

if [ "${http_code}" = "404" ]; then
  echo "No Caddy certificate backup at ${VAULT_CADDY_PATH} — first deploy for this environment, letting Caddy issue its own."
  exit 0
fi

if [ "${http_code}" != "200" ]; then
  echo "::error::Reading ${VAULT_CADDY_PATH} returned HTTP ${http_code}. Refusing to continue: silently skipping the restore would put every rebuild back on a fresh ACME issuance and burn the rate limit." >&2
  exit 1
fi

payload="$(jq -r '.data.data.caddy_data_tar_b64 // empty' /tmp/caddy-vault.json)"
rm -f /tmp/caddy-vault.json

if [ -z "${payload}" ]; then
  echo "Backup entry exists but carries no caddy_data_tar_b64 — treating as no backup."
  exit 0
fi

echo "Restoring caddy_data to ${MATRIX_HOST} (${#payload} b64 chars)."

# 直接往 docker volume 里灌。用一个临时 alpine 容器挂载该卷解包 —— 此时
# caddy 容器可能还不存在(Doco-CD 还没 reconcile), 所以不能用 docker cp 到
# 容器里。volume 不存在时 docker run -v 会自动创建, 正是我们要的。
printf '%s' "${payload}" | base64 -d | ssh "${ssh_opts[@]}" "${host}" '
  set -euo pipefail
  vol="web-saas_caddy_data"
  tmp="$(mktemp /tmp/caddy-data.XXXXXX.tar.gz)"
  cat > "${tmp}"
  if ! tar -tzf "${tmp}" >/dev/null 2>&1; then
    echo "restored archive is not a readable tar.gz" >&2
    rm -f "${tmp}"
    exit 1
  fi
  docker run --rm -v "${vol}":/data -v "${tmp}":/restore.tar.gz:ro alpine:3.21 \
    sh -c "tar -xzf /restore.tar.gz -C /data && ls /data" >/dev/null
  rm -f "${tmp}"
  echo "caddy_data restored into volume ${vol}"
'

echo "Caddy certificates restored; Caddy should start without contacting ACME."
