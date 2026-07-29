#!/usr/bin/env bash
set -euo pipefail

# 把上一次部署备份在 Vault 里的 caddy_data 恢复到主机, 让重建后的 caddy 一起来
# 就发现证书已在, 根本不去调 ACME。同时把同一条 Vault 记录中的完整 PEM
# 材料恢复给非 Caddy 消费者。
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

# 临近到期就不恢复了, 直接让 Caddy 签新的。恢复一张还剩三天的证书, 只会让
# Caddy 一起来立刻进入续期流程 —— 白白多一次重启窗口, 还可能在续期成功前就
# 被 observe 判活。Caddy 自己的续期阈值是剩余寿命的 1/3(90 天证书约 30 天),
# 这里取 14 天: 比它保守, 又不至于频繁作废可复用的备份。
renew_margin_days="${CADDY_CERT_RENEW_MARGIN_DAYS:-14}"

ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20)
host="root@${MATRIX_HOST}"

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

payload="$(jq -r '.data.data.caddy_data_tar_b64 // empty' /tmp/caddy-vault.json)"
not_after="$(jq -r '.data.data.not_after_epoch // empty' /tmp/caddy-vault.json)"
domains="$(jq -r '.data.data.domains // empty' /tmp/caddy-vault.json)"
backed_up_at="$(jq -r '.data.data.backed_up_at // empty' /tmp/caddy-vault.json)"
fullchain_b64="$(jq -r '.data.data.tls_fullchain_pem_b64 // empty' /tmp/caddy-vault.json)"
cert_b64="$(jq -r '.data.data.tls_cert_pem_b64 // empty' /tmp/caddy-vault.json)"
key_b64="$(jq -r '.data.data.tls_key_pem_b64 // empty' /tmp/caddy-vault.json)"
ca_b64="$(jq -r '.data.data.tls_ca_pem_b64 // empty' /tmp/caddy-vault.json)"
trust_bundle_b64="$(jq -r '.data.data.tls_trust_bundle_pem_b64 // empty' /tmp/caddy-vault.json)"
rm -f /tmp/caddy-vault.json

if [ -z "${payload}" ]; then
  echo "Backup entry exists but carries no caddy_data_tar_b64 — treating as no backup."
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
  tar -C "${pem_tmp}" -czf - fullchain.pem cert.pem key.pem ca.pem trust-bundle.pem | ssh "${ssh_opts[@]}" "${host}" \
    "DOMAIN_TLS_DIR=$(printf '%q' "${DOMAIN_TLS_DIR}") CERT_FINGERPRINT=$(printf '%q' "${cert_fingerprint}") bash -c \"\$(printf %s '${remote_script_b64}' | base64 -d)\""

  echo "Restored domain TLS material for non-Caddy consumers at ${DOMAIN_TLS_DIR}/current/."
}

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
    sh -c "tar -xzf /restore.tar.gz -C /data"
  rm -f "${tmp}"

  # 解包成功不等于证书真的落到位(tar 内容不对时 tar 本身仍会成功)。这里确认
  # 至少存在一个 .crt, 否则 caddy 起来还是会去签, 而我们会误以为复用成功了。
  found="$(docker run --rm -v "${vol}":/data alpine:3.21 \
    sh -c "find /data/caddy/certificates -name \"*.crt\" 2>/dev/null | wc -l")"
  if [ "${found}" -eq 0 ]; then
    echo "no .crt found under /data/caddy/certificates after restore" >&2
    exit 1
  fi
  echo "caddy_data restored into ${vol} (${found} certificate file(s))"
'

restore_domain_pem

echo "Caddy certificates restored; Caddy should start serving TLS without contacting ACME."
