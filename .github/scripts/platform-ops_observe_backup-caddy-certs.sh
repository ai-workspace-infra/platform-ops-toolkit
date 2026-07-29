#!/usr/bin/env bash
set -euo pipefail

# 把主机上的 caddy_data(证书 + ACME 账户密钥)备份进 Vault, 供下一次重建恢复。
# 与 platform-ops_deploy_base_restore-caddy-certs.sh 成对。
#
# 放在 observe 之后跑: 那时候证书要么是恢复来的、要么是本轮新签的, 都已经确定
# 有效(observe 刚用它成功握过手)。放在部署早期备份会把一份还没验证过的、
# 甚至半截的 /data 存进去, 下次恢复出来反而更糟。
#
# 备份失败不应该让已经成功的部署变红 —— 服务是好的, 只是下次重建要重签。
# 所以这里出问题记 ::warning:: 而不是 exit 1。但"备份了却是空的"要明确说出来,
# 否则会以为有备份、直到下次重建才发现没有。

: "${MATRIX_HOST:?MATRIX_HOST is required}"
: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_TOKEN:?VAULT_TOKEN is required}"
: "${VAULT_CADDY_PATH:?VAULT_CADDY_PATH is required}"

ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20)
host="root@${MATRIX_HOST}"

# 只打包 certificates 与 acme 账户目录。/data 下还有锁文件和缓存, 存进去没用,
# 还会让每次备份的内容都不一样。
archive_b64="$(ssh "${ssh_opts[@]}" "${host}" '
  set -euo pipefail
  vol="web-saas_caddy_data"
  docker volume inspect "${vol}" >/dev/null 2>&1 || { echo "" ; exit 0; }
  docker run --rm -v "${vol}":/data alpine:3.21 \
    sh -c "cd /data && [ -d caddy ] && tar -czf - caddy 2>/dev/null | base64 -w0 || true"
' || true)"

if [ -z "${archive_b64//[[:space:]]/}" ]; then
  echo "::warning::No caddy_data to back up on ${MATRIX_HOST} (volume or caddy/ directory absent). The next rebuild will have to issue new certificates."
  exit 0
fi

write_url="${VAULT_ADDR%/}/v1/${VAULT_CADDY_PATH}"
body="$(jq -n --arg d "${archive_b64}" --arg h "${MATRIX_HOST}" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{data: {caddy_data_tar_b64: $d, source_host: $h, backed_up_at: $t}}')"

http_code="$(printf '%s' "${body}" | curl -sS -o /dev/null -w '%{http_code}' \
  -X POST -H "X-Vault-Token: ${VAULT_TOKEN}" --data-binary @- "${write_url}" || echo 000)"

case "${http_code}" in
  200|204)
    echo "caddy_data backed up to ${VAULT_CADDY_PATH} ($(printf '%s' "${archive_b64}" | wc -c | tr -d ' ') b64 chars)."
    ;;
  *)
    echo "::warning::Backing up caddy_data to ${VAULT_CADDY_PATH} returned HTTP ${http_code}. The deployment itself is fine; the next rebuild will just have to re-issue certificates." >&2
    ;;
esac
