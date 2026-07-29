#!/usr/bin/env bash
set -euo pipefail

# 把上一次部署备份在 Vault 里的 caddy_data 恢复到主机, 让重建后的 caddy 一起来
# 就发现证书已在, 根本不去调 ACME。
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
: "${VAULT_TOKEN:?VAULT_TOKEN is required}"
: "${VAULT_CADDY_PATH:?VAULT_CADDY_PATH is required}"

# 临近到期就不恢复了, 直接让 Caddy 签新的。恢复一张还剩三天的证书, 只会让
# Caddy 一起来立刻进入续期流程 —— 白白多一次重启窗口, 还可能在续期成功前就
# 被 observe 判活。Caddy 自己的续期阈值是剩余寿命的 1/3(90 天证书约 30 天),
# 这里取 14 天: 比它保守, 又不至于频繁作废可复用的备份。
renew_margin_days="${CADDY_CERT_RENEW_MARGIN_DAYS:-14}"

ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20)
host="root@${MATRIX_HOST}"

read_url="${VAULT_ADDR%/}/v1/${VAULT_CADDY_PATH}"

http_code="$(curl -sS -o /tmp/caddy-vault.json -w '%{http_code}' \
  -H "X-Vault-Token: ${VAULT_TOKEN}" "${read_url}" || echo 000)"

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

echo "Caddy certificates restored; Caddy should start serving TLS without contacting ACME."
