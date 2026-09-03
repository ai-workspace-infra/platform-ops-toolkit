#!/usr/bin/env bash
set -euo pipefail

# 把 Vault 里保存的泛域名证书恢复到主机, 让 Caddy 直接从磁盘提供 TLS,
# 完全不走 ACME。同一份材料也给 stunnel 等非 Caddy 消费者使用。
#
# 记录格式只用通用 PEM(fullchain / cert / key / ca / trust-bundle), 不再保存
# Caddy 的内部目录打包 —— 那样等于把一个私有实现细节冻进跨环境共享的记录里。
#
# 这就是"泛域名证书在有效期内可以无限次重复使用"的那一半: 只要备份里的证书还
# 没到期, 无论重建多少次都恢复同一张, 一次 ACME 都不会发生。到期(或临近到期)
# 才放手让 Caddy 重新签一张, 然后由备份侧存回去, 进入下一个 90 天周期。
#
# 不做这一步的后果: 主机重建会连 caddy_data 卷一起丢, 每次重建都重新签发,
# 撞上 Let's Encrypt "同一组域名 5 次/周" 的限流。2026-07-28 console-uat 就是
# 这么挂的(HTTP 429, retry after 20:38 UTC), 而且没有任何代码能修, 只能等窗口
# 过期。泛域名把每次重建的签发从 3 张降到 1 张, 但 5 次/周的上限还在 ——
# 真正让"反复重建"成立的是这一步。

: "${MATRIX_HOST:?MATRIX_HOST is required}"
: "${VAULT_ADDR:?VAULT_ADDR is required}"
: "${VAULT_ROLE:?VAULT_ROLE is required}"
: "${VAULT_CADDY_PATH:?VAULT_CADDY_PATH is required}"
: "${DOMAIN_TLS_DIR:?DOMAIN_TLS_DIR is required}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?ACTIONS_ID_TOKEN_REQUEST_URL is required (needs id-token: write)}"
: "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:?ACTIONS_ID_TOKEN_REQUEST_TOKEN is required (needs id-token: write)}"

# Bootstrap runs before DNS cutover. Always connect to the IP created by this
# run's CMDB; MATRIX_HOST may still resolve to a deleted previous instance.
cmdb_file="${CMDB_FILE:-cmdb/cmdb.json}"
matrix_ip="$(jq -r --arg host "${MATRIX_HOST}" '.[$host].ip // empty' "${cmdb_file}")"
[[ -n "${matrix_ip}" ]] || {
  echo "::error::No CMDB IP found for ${MATRIX_HOST}; refusing to bootstrap through stale DNS." >&2
  exit 1
}
matrix_user="$(jq -r --arg host "${MATRIX_HOST}" '.[$host].ansible_user // "root"' "${cmdb_file}")"
[[ -n "${matrix_user}" && "${matrix_user}" != "null" ]] || {
  echo "::error::No CMDB SSH user found for ${MATRIX_HOST}." >&2
  exit 1
}

# 临近到期就不恢复了, 直接让 Caddy 签新的。恢复一张还剩三天的证书, 只会让
# Caddy 一起来立刻进入续期流程 —— 白白多一次重启窗口, 还可能在续期成功前就
# 被 observe 判活。Caddy 自己的续期阈值是剩余寿命的 1/3(90 天证书约 30 天),
# 这里取 14 天: 比它保守, 又不至于频繁作废可复用的备份。
renew_margin_days="${CADDY_CERT_RENEW_MARGIN_DAYS:-14}"

ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20)
host="${matrix_user}@${matrix_ip}"

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

read_url="${VAULT_ADDR%/}/v1/${VAULT_CADDY_PATH}"

http_code="$(curl -sS -o /tmp/caddy-vault.json -w '%{http_code}' \
  -H "X-Vault-Token: ${vault_token}" "${read_url}" || echo 000)"

if [ "${http_code}" = "404" ]; then
  echo "No Caddy certificate backup at ${VAULT_CADDY_PATH} — first deploy for this environment, letting Caddy issue its own."
  rm -f /tmp/caddy-vault.json
  exit 0
fi

if [ "${http_code}" != "200" ]; then
  rm -f /tmp/caddy-vault.json
  echo "::error::Reading ${VAULT_CADDY_PATH} returned HTTP ${http_code}. Refusing to continue: silently skipping the restore would put every rebuild back on a fresh ACME issuance and burn the rate limit." >&2
  exit 1
fi

not_after="$(jq -r '.data.data.not_after_epoch // empty' /tmp/caddy-vault.json)"
domains="$(jq -r '.data.data.domains // empty' /tmp/caddy-vault.json)"
backed_up_at="$(jq -r '.data.data.backed_up_at // empty' /tmp/caddy-vault.json)"
fullchain_b64="$(jq -r '.data.data.tls_fullchain_pem_b64 // empty' /tmp/caddy-vault.json)"
cert_b64="$(jq -r '.data.data.tls_cert_pem_b64 // empty' /tmp/caddy-vault.json)"
key_b64="$(jq -r '.data.data.tls_key_pem_b64 // empty' /tmp/caddy-vault.json)"
ca_b64="$(jq -r '.data.data.tls_ca_pem_b64 // empty' /tmp/caddy-vault.json)"
trust_bundle_b64="$(jq -r '.data.data.tls_trust_bundle_pem_b64 // empty' /tmp/caddy-vault.json)"
rm -f /tmp/caddy-vault.json

# 判据是"有没有可用的 PEM 材料", 不是"有没有 caddy_data 打包"。
#
# 这里原来卡的是 caddy_data_tar_b64, 结果 2026-07-31 出现了这样一条记录:
# PEM 五个字段全都有值、证书是 Let's Encrypt 生产签发的 *.onwalk.net、还有 88 天
# 有效期, 唯独 caddy_data_tar_b64 是空的 —— 脚本于是打印 "treating as no backup"
# 掉头就走, 让 Caddy 去 ACME 重签, 撞上 429 之后整个环境起不来。
# 明明手里有一张能用的证书, 却因为它不是以某种特定打包形式存的而拒绝使用。
#
# caddy_data 那条路已经废弃(它把 Caddy 的内部目录布局变成了 Vault 记录格式的
# 一部分, 换个 Caddy 版本就可能对不上)。PEM 是通用格式, 谁都能消费。
if [ -z "${fullchain_b64}" ] || [ -z "${key_b64}" ]; then
  echo "No usable TLS material at ${VAULT_CADDY_PATH} (need tls_fullchain_pem_b64 + tls_key_pem_b64) — letting Caddy issue its own."
  exit 0
fi

# 没有到期元数据的是旧格式备份。恢复它仍然比重签强(Caddy 自己会判断要不要
# 续期), 但要说出来, 否则"为什么这次又签了"会变成一个查不动的问题。
if [ -z "${not_after}" ]; then
  echo "::warning::Backup at ${VAULT_CADDY_PATH} has no not_after_epoch (written by an older version). Restoring it anyway; Caddy will decide whether to renew."
else
  now="$(date -u +%s)"
  days_left="$(( (not_after - now) / 86400 ))"

  if [ "${days_left}" -le 0 ]; then
    echo "Backed-up certificates expired ${days_left#-} day(s) ago (backed up ${backed_up_at}); skipping restore so Caddy issues a fresh one."
    exit 0
  fi

  if [ "${days_left}" -lt "${renew_margin_days}" ]; then
    echo "Backed-up certificates expire in ${days_left} day(s), under the ${renew_margin_days}-day margin; skipping restore so Caddy issues a fresh one now rather than renewing right after startup."
    exit 0
  fi

  echo "Reusing backed-up certificates: ${domains:-unknown domains}, ${days_left} day(s) of validity left (backed up ${backed_up_at})."
fi

# 不把 public wildcard PEM 写进 /etc/xcontrol/web-saas/certs：那个目录属于
# stunnel 的内部 CA/服务证书。这里用按域名隔离的目录，供需要这张公开证书的
# 非 Caddy 服务显式挂载 `${DOMAIN_TLS_DIR}/current/`。
#
# 每次先构造一个版本目录，再原子替换 current 符号链接，读者只会看到同一套
# fullchain/cert/key/ca，不会在证书与私钥切换的中间读到不匹配的文件。
restore_domain_pem() {
  if [ -z "${fullchain_b64}" ] || [ -z "${cert_b64}" ] || [ -z "${key_b64}" ] || [ -z "${ca_b64}" ] || [ -z "${trust_bundle_b64}" ]; then
    echo "::warning::Vault backup at ${VAULT_CADDY_PATH} has no complete public TLS material and trust bundle; restored Caddy state only. Populate tls_trust_bundle_pem_b64 before switching stunnel to the public certificate." >&2
    return 0
  fi

  local pem_tmp cert_fingerprint
  pem_tmp="$(mktemp -d /tmp/domain-tls.XXXXXX)"
  trap 'rm -rf "${pem_tmp}"' RETURN
  umask 077
  printf '%s' "${fullchain_b64}" | base64 -d > "${pem_tmp}/fullchain.pem"
  printf '%s' "${cert_b64}" | base64 -d > "${pem_tmp}/cert.pem"
  printf '%s' "${key_b64}" | base64 -d > "${pem_tmp}/key.pem"
  printf '%s' "${ca_b64}" | base64 -d > "${pem_tmp}/ca.pem"
  printf '%s' "${trust_bundle_b64}" | base64 -d > "${pem_tmp}/trust-bundle.pem"

  openssl x509 -in "${pem_tmp}/fullchain.pem" -noout
  openssl x509 -in "${pem_tmp}/cert.pem" -noout
  openssl x509 -in "${pem_tmp}/ca.pem" -noout
  openssl x509 -in "${pem_tmp}/trust-bundle.pem" -noout
  openssl pkey -in "${pem_tmp}/key.pem" -noout

  if [ "$(openssl x509 -in "${pem_tmp}/fullchain.pem" -noout -fingerprint -sha256)" != \
       "$(openssl x509 -in "${pem_tmp}/cert.pem" -noout -fingerprint -sha256)" ]; then
    echo "::error::tls_fullchain_pem_b64 does not begin with tls_cert_pem_b64; refusing to restore mismatched TLS material." >&2
    return 1
  fi

  if [ "$(openssl x509 -in "${pem_tmp}/cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)" != \
       "$(openssl pkey -in "${pem_tmp}/key.pem" -pubout -outform DER | openssl dgst -sha256)" ]; then
    echo "::error::tls_key_pem_b64 does not match tls_cert_pem_b64; refusing to restore mismatched TLS material." >&2
    return 1
  fi

  cert_fingerprint="$(openssl x509 -in "${pem_tmp}/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')"
  local remote_script remote_script_b64
  remote_script="$(cat <<'REMOTE'
set -euo pipefail

case "${DOMAIN_TLS_DIR}" in
  /etc/xcontrol/tls/*) ;;
  *)
    echo "refusing unsafe DOMAIN_TLS_DIR: ${DOMAIN_TLS_DIR}" >&2
    exit 1 ;;
esac

base_dir="${DOMAIN_TLS_DIR}"
versions_dir="${base_dir}/versions"
version_dir="${versions_dir}/${CERT_FINGERPRINT}"
tmp_dir="${versions_dir}/.restore-${CERT_FINGERPRINT}"

install -d -m 0700 -o root -g root "${versions_dir}"
rm -rf "${tmp_dir}"
install -d -m 0700 -o root -g root "${tmp_dir}"
tar -xzf - -C "${tmp_dir}"

for file in fullchain.pem cert.pem key.pem ca.pem trust-bundle.pem; do
  test -s "${tmp_dir}/${file}"
done
chmod 0644 "${tmp_dir}/fullchain.pem" "${tmp_dir}/cert.pem" "${tmp_dir}/ca.pem" "${tmp_dir}/trust-bundle.pem"
chmod 0600 "${tmp_dir}/key.pem"
chown root:root "${tmp_dir}/fullchain.pem" "${tmp_dir}/cert.pem" "${tmp_dir}/key.pem" "${tmp_dir}/ca.pem" "${tmp_dir}/trust-bundle.pem"

rm -rf "${version_dir}"
mv "${tmp_dir}" "${version_dir}"
ln -s "versions/${CERT_FINGERPRINT}" "${base_dir}/.current-${CERT_FINGERPRINT}"
mv -Tf "${base_dir}/.current-${CERT_FINGERPRINT}" "${base_dir}/current"
REMOTE
  )"
  remote_script_b64="$(printf '%s' "${remote_script}" | base64 -w0)"

  # stdin belongs to the tar stream. Pass the small remote program as an
  # encoded command argument instead of a here-document, otherwise the here-
  # document would replace the archive before ssh can forward it.
  local success=false
  for attempt in 1 2 3 4 5; do
    local remote_command
    remote_command="env DOMAIN_TLS_DIR=$(printf '%q' "${DOMAIN_TLS_DIR}") CERT_FINGERPRINT=$(printf '%q' "${cert_fingerprint}") bash -c \"\$(printf %s '${remote_script_b64}' | base64 -d)\""
    if [[ "${matrix_user}" != "root" ]]; then
      remote_command="sudo -n ${remote_command}"
    fi
    if tar -C "${pem_tmp}" -czf - fullchain.pem cert.pem key.pem ca.pem trust-bundle.pem | ssh "${ssh_opts[@]}" "${host}" \
      "${remote_command}"; then
      success=true
      break
    fi
    echo "SSH restore attempt ${attempt} failed; retrying in 5s..." >&2
    sleep 5
  done

  if [[ "${success}" != "true" ]]; then
    echo "::error::Failed to restore domain TLS material to ${host} after multiple attempts." >&2
    return 1
  fi

  echo "Restored domain TLS material for non-Caddy consumers at ${DOMAIN_TLS_DIR}/current/."
}

# 只落 PEM。不再往 caddy_data 卷里灌 tar ——
#
# 那条路要求 Vault 记录里保存 Caddy 的内部目录布局(certificates/<issuer>/<name>/
# 三件套 + certmagic 的 .json 元数据), 等于把一个私有实现细节冻进了跨环境共享的
# 记录格式里: Caddy 换个版本、换个 issuer 目录名, 恢复出来的东西就不被识别,
# 而表现是"恢复成功但 Caddy 还是去签了", 极难查。
#
# 改成: 证书以 PEM 落到 DOMAIN_TLS_DIR, Caddyfile 用 `tls <fullchain> <key>`
# 直接指过去(见 playbooks 的 web_saas_host_config)。那是 Caddy 的公开接口,
# 而且完全不走 ACME —— 不是"让 Caddy 发现证书已在", 而是根本不给它签发的机会。
restore_domain_pem

# 只陈述这一步真正做到的事: 证书写到磁盘了。
#
# 这里原来写的是 "Caddy serves it from disk and will not contact ACME" ——
# 那是一句谎话。本脚本只负责把 PEM 落盘, Caddy 用不用它取决于 Caddyfile 里
# 是不是 `tls <fullchain> <key>`, 而那是 playbooks 的 web_saas_host_config
# 渲染的、完全在本脚本控制之外。2026-07-31 run 30623661870 就是反例: 这行日志
# 照常打印, 而 Caddyfile 仍是 ACME 模式、caddy_data 里一张证书都没有,
# 证书躺在磁盘上没人读。
#
# 日志断言了一件自己没有验证过的事, 就是在制造假绿: 后面的人看到这行会以为
# 复用已经生效, 从而把排查方向引到别处去。真正的验证在下面那个断言步骤,
# 它检查渲染出来的 Caddyfile 是否确实引用了这些文件。
echo "Wrote the wildcard certificate from Vault to ${DOMAIN_TLS_DIR}/current/."
echo "Whether Caddy actually serves it depends on the Caddyfile rendered by the next step; that is asserted separately."
