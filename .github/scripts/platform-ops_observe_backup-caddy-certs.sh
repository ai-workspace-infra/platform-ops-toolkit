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
: "${VAULT_ROLE:?VAULT_ROLE is required}"
: "${VAULT_CADDY_PATH:?VAULT_CADDY_PATH is required}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?ACTIONS_ID_TOKEN_REQUEST_URL is required (needs id-token: write)}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?ACTIONS_ID_TOKEN_REQUEST_TOKEN is required (needs id-token: write)}"

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
rm -f "${login_body}"
trap - EXIT

ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20)
# Observe runs before DNS cutover.  Resolve the current run's host from CMDB;
# MATRIX_HOST can still resolve to the deleted previous replica.
cmdb_file="${CMDB_FILE:-cmdb/cmdb.json}"
matrix_ip="$(jq -r --arg host "${MATRIX_HOST}" '.[$host].ip // empty' "${cmdb_file}")"
if [[ -z "${matrix_ip}" ]]; then
  echo "::warning::No CMDB IP found for ${MATRIX_HOST}; skipping certificate backup." >&2
  exit 0
fi
host="root@${matrix_ip}"

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

    # 只认生产 CA 签出来的证书。Caddy 把证书按签发方分目录存
    # (certificates/<issuer>/...), 其中可能同时存在 staging 的那份 ——
    # LE 生产限流时 Caddy 会从 staging 拿到一张能用的证书, 而它由
    # 一个浏览器不信任的根签发。把它备份进 Vault 的后果比不备份更糟:
    # 之后每次重建都会"成功恢复"一张没人信任的证书, 而且看起来像复用生效了。
    # 2026-07-31 主机上就正好只有 staging 那份。
    prod_certs=\$(find caddy/certificates -name \"*.crt\" 2>/dev/null | grep -v staging || true)
    [ -z \"\$prod_certs\" ] && { echo NO_PROD_CERTS; exit 0; }

    earliest=\"\"
    domains=\"\"
    for crt in \$prod_certs; do
      nd=\$(openssl x509 -in \"\$crt\" -noout -enddate 2>/dev/null | cut -d= -f2) || continue
      ts=\$(date -u -d \"\$nd\" +%s 2>/dev/null) || continue
      [ -z \"\$earliest\" ] && earliest=\$ts
      [ \"\$ts\" -lt \"\$earliest\" ] && earliest=\$ts
      sub=\$(openssl x509 -in \"\$crt\" -noout -subject 2>/dev/null | sed -n \"s/.*CN *= *//p\")
      domains=\"\$domains \$sub\"
    done

    [ -z \"\$earliest\" ] && { echo NO_CERTS; exit 0; }

    # 除了整包 caddy_data, 再单独导出这张泛域名证书的 PEM 材料, 让 Vault 里
    # 这条记录能被 Caddy 之外的东西直接消费(不必解 tar、也不必懂 Caddy 的
    # 目录布局)。取覆盖域名最多的那张 —— 泛域名证书就是它。
    wild=\$(printf '%s\n' \"\$prod_certs\" | grep \"wildcard_\" | head -1)
    [ -z \"\$wild\" ] && wild=\$(printf '%s\n' \"\$prod_certs\" | head -1)
    if [ -n \"\$wild\" ]; then
      key=\"\${wild%.crt}.key\"
      echo \"CERT_B64=\$(base64 -w0 < \"\$wild\")\"
      [ -f \"\$key\" ] && echo \"KEY_B64=\$(base64 -w0 < \"\$key\")\"
      # Caddy 的 .crt 是完整链: 第一段是叶证书, 其后是签发 CA。拆出来分别存,
      # 免得消费方自己去猜哪一段是哪个。
      awk \"/BEGIN CERT/{n++} n==1\" \"\$wild\" | base64 -w0 | sed \"s/^/LEAF_B64=/\"
      awk \"/BEGIN CERT/{n++} n>1\" \"\$wild\"  | base64 -w0 | sed \"s/^/CA_B64=/\"
    fi

    echo \"NOT_AFTER=\$earliest\"
    echo \"DOMAINS=\$(echo \$domains | tr -s \" \")\"
  "
' || true)"

cert_b64="$(printf '%s\n' "${remote_out}" | sed -n 's/^CERT_B64=//p' | head -1)"
key_b64="$(printf '%s\n' "${remote_out}" | sed -n 's/^KEY_B64=//p' | head -1)"
leaf_b64="$(printf '%s\n' "${remote_out}" | sed -n 's/^LEAF_B64=//p' | head -1)"
ca_b64="$(printf '%s\n' "${remote_out}" | sed -n 's/^CA_B64=//p' | head -1)"

case "${remote_out}" in
  *NO_VOLUME*)
    echo "::warning::No caddy_data volume on ${MATRIX_HOST}; nothing to back up. The next rebuild will have to issue new certificates."
    exit 0 ;;
  *NO_PROD_CERTS*)
    echo "::warning::${MATRIX_HOST} only has staging/untrusted certificates (production ACME is likely rate limited). Not backing them up — restoring a staging certificate later would look like reuse while serving a certificate no browser trusts."
    exit 0 ;;
  *NO_CADDY_DIR*|*NO_CERTS*)
    echo "::warning::caddy_data on ${MATRIX_HOST} holds no certificates yet (Caddy may still be issuing). Nothing backed up."
    exit 0 ;;
esac

not_after="$(printf '%s\n' "${remote_out}" | sed -n 's/^NOT_AFTER=//p' | head -1)"
domains="$(printf '%s\n' "${remote_out}" | sed -n 's/^DOMAINS=//p' | head -1)"

if [ -z "${cert_b64}" ] || [ -z "${not_after}" ]; then
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
# Caddy can export its leaf and issuer chain but not the public root trust
# bundle used by stunnel clients. Preserve that operator-managed field on every
# certificate backup rather than silently deleting it with the KV replacement.
existing_record="$(curl -sS -H "X-Vault-Token: ${vault_token}" "${write_url}" || true)"
trust_bundle_b64="$(printf '%s' "${existing_record}" | jq -r '.data.data.tls_trust_bundle_pem_b64 // empty' 2>/dev/null || true)"
# 只写通用 PEM。曾经还写过一个 caddy_data_tar_b64(Caddy 内部目录打包), 已废弃:
# 它把 Caddy 的私有布局变成了记录格式的一部分, 而且恢复侧一旦拿它当"有没有备份"
# 的判据, 就会在 PEM 齐全、证书完全可用的情况下判定成"没有备份"(2026-07-31 就是
# 这么让一张还有 88 天有效期的证书被跳过、去重签然后撞 429 的)。公开
# 根信任 bundle 不是 Caddy 数据的一部分，故只保留现有 Vault 值。
body="$(jq -n \
  --arg h "${MATRIX_HOST}" \
  --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg na "${not_after}" \
  --arg dom "${domains}" \
  --arg fullchain "${cert_b64}" \
  --arg key "${key_b64}" \
  --arg leaf "${leaf_b64}" \
  --arg ca "${ca_b64}" \
  --arg trust_bundle "${trust_bundle_b64}" \
  '{data: {
      tls_fullchain_pem_b64: $fullchain,
      tls_cert_pem_b64:      $leaf,
      tls_key_pem_b64:       $key,
      tls_ca_pem_b64:        $ca,
      tls_trust_bundle_pem_b64: $trust_bundle,
      source_host: $h, backed_up_at: $t, not_after_epoch: $na, domains: $dom}}')"

http_code="$(printf '%s' "${body}" | curl -sS -o /dev/null -w '%{http_code}' \
  -X POST -H "X-Vault-Token: ${vault_token}" --data-binary @- "${write_url}" || echo 000)"

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
