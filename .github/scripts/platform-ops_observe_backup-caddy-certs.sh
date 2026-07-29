#!/usr/bin/env bash
set -euo pipefail

# 把主机上的 caddy_data(证书 + ACME 账户密钥)备份进 Vault, 供下一次重建恢复。
# 与 platform-ops_deploy_base_restore-caddy-certs.sh 成对。
#
# 连同证书的到期时间一起存。恢复侧靠这个元数据判断"还在有效期内吗" ——
# 有效期内就直接复用, 不管重建多少次都不再调 ACME; 过期了才让 Caddy 重新签。
# 这就是"泛域名证书在有效期内可以无限次重复使用"的实现方式。
#
# 放在 observe 之后跑: 那时候证书要么是恢复来的、要么是本轮新签的, 都已经确定
# 有效(observe 刚用它成功握过手)。放在部署早期备份会把一份还没验证过的、
# 甚至半截的 /data 存进去, 下次恢复出来反而更糟。
#
# 备份失败不应该让已经成功的部署变红 —— 服务是好的, 只是下次重建要重签。
# 所以这里出问题记 ::warning:: 而不是 exit 1。

: "${MATRIX_HOST:?MATRIX_HOST is required}"
: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_TOKEN:?VAULT_TOKEN is required}"
: "${VAULT_CADDY_PATH:?VAULT_CADDY_PATH is required}"

ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20)
host="root@${MATRIX_HOST}"

# 一次 ssh 里做完三件事: 打包、取最早到期时间、取覆盖的域名。分三次 ssh 会
# 在两次调用之间出现证书被续期的窗口, 存下来的到期时间就跟内容对不上了。
#
# 只打包 caddy/ 子目录(证书 + ACME 账户)。/data 下还有锁文件和缓存, 存进去
# 没用, 还会让每次备份的字节都不一样、看不出到底变没变。
#
# 最早到期: 一份 caddy_data 里可能有多张证书, 复用的安全上界由最早到期的那张
# 决定 —— 按最晚的算会让一张已经过期的证书被当成"还能用"。
remote_out="$(ssh "${ssh_opts[@]}" "${host}" '
  set -euo pipefail
  vol="web-saas_caddy_data"
  docker volume inspect "${vol}" >/dev/null 2>&1 || { echo "NO_VOLUME"; exit 0; }

  docker run --rm -v "${vol}":/data alpine:3.21 sh -c "
    set -e
    apk add --no-cache openssl >/dev/null 2>&1 || true
    cd /data
    [ -d caddy ] || { echo NO_CADDY_DIR; exit 0; }

    earliest=\"\"
    domains=\"\"
    for crt in \$(find caddy/certificates -name \"*.crt\" 2>/dev/null); do
      nd=\$(openssl x509 -in \"\$crt\" -noout -enddate 2>/dev/null | cut -d= -f2) || continue
      ts=\$(date -u -d \"\$nd\" +%s 2>/dev/null) || continue
      [ -z \"\$earliest\" ] && earliest=\$ts
      [ \"\$ts\" -lt \"\$earliest\" ] && earliest=\$ts
      sub=\$(openssl x509 -in \"\$crt\" -noout -subject 2>/dev/null | sed -n \"s/.*CN *= *//p\")
      domains=\"\$domains \$sub\"
    done

    [ -z \"\$earliest\" ] && { echo NO_CERTS; exit 0; }
    echo \"NOT_AFTER=\$earliest\"
    echo \"DOMAINS=\$(echo \$domains | tr -s \" \")\"
    echo \"TAR_B64=\$(tar -czf - caddy | base64 -w0)\"
  "
' || true)"

case "${remote_out}" in
  *NO_VOLUME*)
    echo "::warning::No caddy_data volume on ${MATRIX_HOST}; nothing to back up. The next rebuild will have to issue new certificates."
    exit 0 ;;
  *NO_CADDY_DIR*|*NO_CERTS*)
    echo "::warning::caddy_data on ${MATRIX_HOST} holds no certificates yet (Caddy may still be issuing). Nothing backed up."
    exit 0 ;;
esac

not_after="$(printf '%s\n' "${remote_out}" | sed -n 's/^NOT_AFTER=//p' | head -1)"
domains="$(printf '%s\n' "${remote_out}" | sed -n 's/^DOMAINS=//p' | head -1)"
archive_b64="$(printf '%s\n' "${remote_out}" | sed -n 's/^TAR_B64=//p' | head -1)"

if [ -z "${archive_b64}" ] || [ -z "${not_after}" ]; then
  echo "::warning::Could not read a complete certificate bundle from ${MATRIX_HOST}; skipping backup rather than storing a partial one." >&2
  exit 0
fi

now="$(date -u +%s)"
days_left="$(( (not_after - now) / 86400 ))"

# 已经过期的就别存了 —— 存进去只会让下次恢复浪费一轮, 而且会盖掉可能还有效的
# 那一份。
if [ "${days_left}" -le 0 ]; then
  echo "::warning::Certificates on ${MATRIX_HOST} already expired ($(date -u -r "${not_after}" 2>/dev/null || echo "${not_after}")); not backing them up."
  exit 0
fi

write_url="${VAULT_ADDR%/}/v1/${VAULT_CADDY_PATH}"
body="$(jq -n \
  --arg d "${archive_b64}" \
  --arg h "${MATRIX_HOST}" \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg na "${not_after}" \
  --arg dom "${domains}" \
  '{data: {caddy_data_tar_b64: $d, source_host: $h, backed_up_at: $t, not_after_epoch: $na, domains: $dom}}')"

http_code="$(printf '%s' "${body}" | curl -sS -o /dev/null -w '%{http_code}' \
  -X POST -H "X-Vault-Token: ${VAULT_TOKEN}" --data-binary @- "${write_url}" || echo 000)"

case "${http_code}" in
  200|204)
    echo "Backed up caddy_data to ${VAULT_CADDY_PATH}."
    echo "  domains:    ${domains}"
    echo "  valid for:  ${days_left} more day(s)"
    echo "  reusable:   every rebuild until then restores this instead of calling ACME"
    ;;
  *)
    echo "::warning::Backing up caddy_data to ${VAULT_CADDY_PATH} returned HTTP ${http_code}. The deployment itself is fine; the next rebuild will just have to re-issue certificates." >&2
    ;;
esac
