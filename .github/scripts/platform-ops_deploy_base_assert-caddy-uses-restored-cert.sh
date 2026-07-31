#!/usr/bin/env bash
set -euo pipefail

# 断言: 磁盘上既然有恢复下来的泛域名证书, 渲染出来的 Caddyfile 就必须真的
# 引用它。
#
# 为什么需要这个断言。恢复脚本只能保证"证书写到磁盘了", 用不用它取决于
# Caddyfile 里是不是 `tls <fullchain> <key>` —— 那是 playbooks 渲染的, 在恢复
# 脚本控制之外。两者之间没有任何强制关系, 于是出现过这样一次(2026-07-31
# run 30623661870):
#
#   恢复步骤:  Reusing backed-up certificates ... 88 day(s) of validity left
#   主机磁盘:  /etc/xcontrol/tls/onwalk.net/current/ 五个 PEM 俱全
#   Caddyfile: tls { dns cloudflare ... }        <- 仍然是 ACME 模式
#   caddy_data: certificates 目录为空            <- 一张证书都没有
#   结果:      撞 429, TLS 握手失败, observe 与 switch_dns 双双变红
#
# 每一步都"成功"了, 合起来什么也没做成。这正是本仓一直在对付的那类失败:
# 日志断言了一件没人验证过的事。所以这里补一个真正会失败的检查 ——
# 有证书却没被引用, 就是配置错了, 必须红, 不能等到 observe 那里才以
# "TLS handshake failed" 这种毫无指向性的形式暴露出来。
#
# 反过来: 磁盘上没有恢复的证书是正常的(首次部署, 或证书临近到期被主动跳过),
# 那种情况下 Caddy 本来就该走 ACME, 不做任何断言。

: "${MATRIX_HOST:?MATRIX_HOST is required}"
: "${DOMAIN_TLS_DIR:?DOMAIN_TLS_DIR is required}"

ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20)
host="root@${MATRIX_HOST}"
caddyfile="/etc/xcontrol/web-saas/Caddyfile"

result="$(ssh "${ssh_opts[@]}" "${host}" \
  "DOMAIN_TLS_DIR=$(printf '%q' "${DOMAIN_TLS_DIR}") CADDYFILE=$(printf '%q' "${caddyfile}") bash -s" <<'REMOTE'
set -euo pipefail
fullchain="${DOMAIN_TLS_DIR}/current/fullchain.pem"
key="${DOMAIN_TLS_DIR}/current/key.pem"

if [ ! -s "${fullchain}" ] || [ ! -s "${key}" ]; then
  echo "NO_RESTORED_CERT"
  exit 0
fi

if [ ! -s "${CADDYFILE}" ]; then
  echo "NO_CADDYFILE"
  exit 0
fi

# Caddyfile 必须把这两个路径当作 tls 指令的参数。只 grep 路径不够 —— 路径也
# 可能只出现在注释里。
if grep -qE "^[[:space:]]*tls[[:space:]]+${fullchain}[[:space:]]+${key}[[:space:]]*$" "${CADDYFILE}"; then
  echo "USES_RESTORED"
elif grep -qE "^[[:space:]]*dns[[:space:]]+cloudflare" "${CADDYFILE}"; then
  echo "STILL_ACME"
else
  echo "UNKNOWN_TLS_MODE"
fi
REMOTE
)"

case "${result}" in
  *NO_RESTORED_CERT*)
    echo "No restored certificate on ${MATRIX_HOST} — Caddy is expected to obtain one via ACME. Nothing to assert."
    exit 0 ;;
  *NO_CADDYFILE*)
    echo "::warning::${caddyfile} does not exist yet on ${MATRIX_HOST}; cannot assert which TLS mode Caddy will use."
    exit 0 ;;
  *USES_RESTORED*)
    echo "Confirmed: the rendered Caddyfile serves the restored wildcard certificate from ${DOMAIN_TLS_DIR}/current/ — Caddy will not contact ACME for it."
    exit 0 ;;
  *STILL_ACME*)
    echo "::error::${MATRIX_HOST} has a restored wildcard certificate at ${DOMAIN_TLS_DIR}/current/, but the rendered Caddyfile still uses ACME DNS-01." >&2
    echo "::error::Caddy would ignore the restored certificate and try to issue a new one, burning the Let's Encrypt rate limit for no reason." >&2
    echo "::error::Expected the Caddyfile to contain: tls ${DOMAIN_TLS_DIR}/current/fullchain.pem ${DOMAIN_TLS_DIR}/current/key.pem" >&2
    echo "::error::This usually means the restore step ran after the Caddyfile was rendered, or the playbooks role does not support serving a restored certificate yet." >&2
    exit 1 ;;
  *)
    echo "::error::Could not determine the TLS mode in ${caddyfile} on ${MATRIX_HOST} (neither a restored-cert tls directive nor an ACME dns directive was found). Refusing to report success for an unverified TLS configuration." >&2
    exit 1 ;;
esac
