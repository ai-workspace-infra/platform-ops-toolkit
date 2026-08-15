#!/usr/bin/env bash
set -euo pipefail

# 诊断: 磁盘上既然有恢复下来的泛域名证书, 渲染出来的 Caddyfile 就必须真的
# 引用它。
#
# 此脚本不再属于 deploy_base 的 Pre-DNS 阻断条件。部署门只验证内部容器
# Running；DNS 切换之后由 domain-cd-observe-endpoints.sh 从外部验证 TLS / HTTP。
# 保留这个脚本供故障诊断或需要明确定位 "恢复证书是否正在被 Caddy 提供" 的场景
# 使用。
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
# This job also runs before DNS cutover, so use the current run's CMDB IP for
# SSH. MATRIX_HOST can still point at a deleted previous instance.
cmdb_file="${CMDB_FILE:-cmdb/cmdb.json}"
matrix_ip="$(jq -r --arg host "${MATRIX_HOST}" '.[$host].ip // empty' "${cmdb_file}")"
[[ -n "${matrix_ip}" ]] || {
  echo "::error::No CMDB IP found for ${MATRIX_HOST}; refusing to inspect a host through stale DNS." >&2
  exit 1
}
# 握手时要带的 SNI。泛域名证书对任何子域都一样, 这里用 MATRIX_HOST 即可。
sni_host="${SNI_HOST:-${MATRIX_HOST}}"

ssh_opts=(-i ~/.ssh/id_deploy -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=20)
host="root@${matrix_ip}"
caddyfile="/etc/xcontrol/web-saas/Caddyfile"

result="$(ssh "${ssh_opts[@]}" "${host}" \
  "DOMAIN_TLS_DIR=$(printf '%q' "${DOMAIN_TLS_DIR}") CADDYFILE=$(printf '%q' "${caddyfile}") SNI_HOST=$(printf '%q' "${sni_host}") bash -s" <<'REMOTE'
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
  :
elif grep -qE "^[[:space:]]*dns[[:space:]]+cloudflare" "${CADDYFILE}"; then
  echo "STILL_ACME"; exit 0
else
  echo "UNKNOWN_TLS_MODE"; exit 0
fi

# 到这里只证明了"磁盘上那份配置是对的", 还没证明 Caddy 真的在跑它。
#
# 这一条是本脚本第一版漏掉的, 而它恰恰是 2026-07-31 run 30629233143 的失败点:
# 断言打印了 "Confirmed ... Caddy will not contact ACME", 而容器比 Caddyfile
# 早启动 24 分钟、仍在跑那份 ACME 配置。断言检查了文件, 却把结论说成了进程 ——
# 与它要取代的那句假绿是同一类错误, 只是换了个地方。
#
# 所以这里比对**实际握手拿到的证书**与磁盘上那张的指纹。这是唯一的地面真相:
# 指纹一致 => Caddy 确实在用恢复来的那张, 没有另行签发。
if [ -z "$(docker ps -q --filter name='^web-saas-caddy$')" ]; then
  echo "CADDY_NOT_RUNNING"; exit 0
fi

want="$(openssl x509 -in "${fullchain}" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"

# With `set -e -o pipefail`, a refused or incomplete TLS handshake makes the
# openssl pipeline exit before we can emit NO_TLS_HANDSHAKE. Keep that expected
# probe failure as data instead: an empty fingerprint is handled below with a
# precise diagnostic result.
got="$({
  echo | timeout 10s openssl s_client -connect 127.0.0.1:443 -servername "${SNI_HOST}" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
} || true)"

if [ -z "${got}" ]; then
  echo "NO_TLS_HANDSHAKE"
elif [ "${want}" = "${got}" ]; then
  echo "SERVING_RESTORED"
else
  echo "SERVING_OTHER want=${want} got=${got}"
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
  *SERVING_RESTORED*)
    echo "Confirmed by TLS handshake: Caddy on ${MATRIX_HOST} is serving the wildcard certificate restored from Vault (fingerprints match). No ACME issuance took place."
    exit 0 ;;
  *CADDY_NOT_RUNNING*)
    echo "::warning::The Caddyfile correctly references the restored certificate, but web-saas-caddy is not running yet (Doco-CD may not have started it). Cannot confirm by handshake; the endpoint observation later in the pipeline is the backstop."
    exit 0 ;;
  *NO_TLS_HANDSHAKE*)
    echo "::error::${MATRIX_HOST} has a restored certificate and a Caddyfile that references it, but Caddy answered no TLS handshake on :443." >&2
    echo "::error::Most likely Caddy is still running an older config — it reads the Caddyfile only at startup, and a bind-mounted file changing does not restart it." >&2
    echo "::error::Check: docker inspect web-saas-caddy --format '{{.State.StartedAt}}' against the Caddyfile mtime." >&2
    exit 1 ;;
  *SERVING_OTHER*)
    echo "::error::Caddy on ${MATRIX_HOST} is serving a certificate that is NOT the one restored from Vault:" >&2
    echo "::error::  ${result##*SERVING_OTHER }" >&2
    echo "::error::That means it issued (or is serving) something else — the restored certificate is being ignored, and ACME rate limit is being consumed for nothing." >&2
    echo "::error::A stale process is the usual cause: Caddy reads its config only at startup, so rendering a new Caddyfile does not take effect until the container restarts." >&2
    exit 1 ;;
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
