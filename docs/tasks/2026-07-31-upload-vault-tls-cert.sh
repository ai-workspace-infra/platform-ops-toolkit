#!/usr/bin/env bash
#==============================================================#
# File      :   2026-07-31-upload-vault-tls-cert.sh            #
# Desc      :   Upload / renew the wildcard TLS material in     #
#               kv/CICD/domains/<domain>, validating first      #
# Usage     :   ./2026-07-31-upload-vault-tls-cert.sh <domain> \
#                 --fullchain <f> --key <f> [--trust-bundle <f>]
#               ./2026-07-31-upload-vault-tls-cert.sh <domain> --from-host <host>
#==============================================================#
#
# 为什么要有这个脚本: 这条记录是 sit/uat/prod 三个环境共用的证书来源, 一旦写进
# 一份坏的(过期 / staging 签发 / 私钥不配对 / SAN 不覆盖泛域名), 三个环境会一起
# "成功恢复"一张没人信任的证书 —— 那比没有证书更难查, 因为链路看起来是通的。
#
# 所以这里的重点不是上传, 是上传**之前**的六项校验。校验不过一律拒绝写入。
#
# 写入前会先读一次现有记录并整条合并: kv v2 的写入是整条替换而不是字段合并,
# 直接 POST 只带新字段会把 tls_trust_bundle_pem_b64 这类运维自己维护的字段
# 静默清空 —— 这正是 caddy_data_tar_b64 那次踩过的坑的反面版本。

set -euo pipefail

DOMAIN=""
FULLCHAIN=""
KEY=""
TRUST_BUNDLE=""
FROM_HOST=""
DRY_RUN=false

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --fullchain <file>     完整链 PEM (叶证书 + 签发 CA)
  --key <file>           私钥 PEM
  --trust-bundle <file>  公共根信任包; 省略则保留 Vault 中现有的那份
  --from-host <host>     不给文件, 直接从该主机运行中的 Caddy 导出当前证书
  --dry-run              只校验、不写入
  -h, --help

Env:
  VAULT_ADDR   默认 https://vault.svc.plus
  VAULT_TOKEN  必须
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --fullchain)    FULLCHAIN="$2"; shift 2 ;;
    --key)          KEY="$2"; shift 2 ;;
    --trust-bundle) TRUST_BUNDLE="$2"; shift 2 ;;
    --from-host)    FROM_HOST="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    *)              [ -z "${DOMAIN}" ] && DOMAIN="$1" || { echo "多余参数: $1" >&2; exit 2; }; shift ;;
  esac
done

[ -n "${DOMAIN}" ] || { echo "错误: 未提供域名。" >&2; usage >&2; exit 2; }
: "${VAULT_TOKEN:?错误: 需要 VAULT_TOKEN}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
VAULT_PATH="kv/data/CICD/domains/${DOMAIN}"

for c in openssl curl jq base64; do
  command -v "$c" >/dev/null || { echo "错误: 缺少 ${c}" >&2; exit 1; }
done

work="$(mktemp -d /tmp/vault-tls.XXXXXX)"
trap 'rm -rf "${work}"' EXIT

# ---------------------------------------------------------------- 取得材料
if [ -n "${FROM_HOST}" ]; then
  echo ">> 从 ${FROM_HOST} 运行中的 Caddy 导出当前证书..."
  # 只取生产签发目录。Caddy 在生产限流时会从 staging 拿到一张能用但不被信任的
  # 证书, 那张绝不能进 Vault。
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${FROM_HOST}" '
    docker run --rm -v web-saas_caddy_data:/data alpine:3.21 sh -c "
      cd /data
      crt=\$(find caddy/certificates -name \"wildcard_*.crt\" 2>/dev/null | grep -v staging | head -1)
      [ -z \"\$crt\" ] && exit 3
      echo FULLCHAIN_B64=\$(base64 -w0 < \"\$crt\")
      echo KEY_B64=\$(base64 -w0 < \"\${crt%.crt}.key\")
    "' > "${work}/remote" || { echo "错误: 主机上没有生产签发的泛域名证书(可能只有 staging)。" >&2; exit 1; }
  sed -n 's/^FULLCHAIN_B64=//p' "${work}/remote" | base64 -d > "${work}/fullchain.pem"
  sed -n 's/^KEY_B64=//p'       "${work}/remote" | base64 -d > "${work}/key.pem"
else
  [ -n "${FULLCHAIN}" ] && [ -n "${KEY}" ] || {
    echo "错误: 需要 --fullchain 与 --key, 或改用 --from-host。" >&2; exit 2; }
  cp "${FULLCHAIN}" "${work}/fullchain.pem"
  cp "${KEY}"       "${work}/key.pem"
fi

# 叶证书 = 链里第一段; 签发 CA = 其余部分。分开存, 免得消费方自己猜。
awk '/BEGIN CERT/{n++} n==1' "${work}/fullchain.pem" > "${work}/cert.pem"
awk '/BEGIN CERT/{n++} n>1'  "${work}/fullchain.pem" > "${work}/ca.pem"

# ---------------------------------------------------------------- 六项校验
fail=0
note() { printf '  %-46s %s\n' "$1" "$2"; }

echo ">> 校验证书材料..."

# 1. 能不能解析
if openssl x509 -in "${work}/cert.pem" -noout >/dev/null 2>&1; then
  note "1. 叶证书可解析" "✅"
else
  note "1. 叶证书可解析" "❌ 无法解析"; fail=1
fi

# 2. SAN 必须覆盖泛域名。只有 CN 不算 —— 现代客户端只看 SAN。
sans="$(openssl x509 -in "${work}/cert.pem" -noout -ext subjectAltName 2>/dev/null | tr -d ' ' | tr ',' '\n' | sed -n 's/^DNS://p' | paste -sd' ' -)"
if printf '%s' "${sans}" | grep -qx -- "\*\.${DOMAIN}" || printf '%s ' ${sans} | grep -q -- "\*\.${DOMAIN} "; then
  note "2. SAN 覆盖 *.${DOMAIN}" "✅  (${sans})"
else
  note "2. SAN 覆盖 *.${DOMAIN}" "❌  实际: ${sans:-无}"; fail=1
fi

# 3. 私钥必须与证书配对。不配对的话 Caddy 会起不来, 但要到部署那一刻才发现。
pub_c="$(openssl x509 -in "${work}/cert.pem" -noout -pubkey 2>/dev/null | openssl md5)"
pub_k="$(openssl pkey -in "${work}/key.pem" -pubout 2>/dev/null | openssl md5)"
if [ -n "${pub_c}" ] && [ "${pub_c}" = "${pub_k}" ]; then
  note "3. 私钥与证书配对" "✅"
else
  note "3. 私钥与证书配对" "❌ 不匹配"; fail=1
fi

# 4. 不能是 staging / 自签。这是最容易被忽略的一项: staging 证书功能完全正常,
#    只是没有浏览器信任它, 存进去之后一切看起来都对。
issuer="$(openssl x509 -in "${work}/cert.pem" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
if printf '%s' "${issuer}" | grep -qiE "staging|STAGING|\(STAGING\)"; then
  note "4. 非 staging 签发" "❌  ${issuer}"; fail=1
elif [ "$(openssl x509 -in "${work}/cert.pem" -noout -subject 2>/dev/null | sed 's/^subject=//')" = "${issuer}" ]; then
  note "4. 非 staging 签发" "❌  自签证书"; fail=1
else
  note "4. 非 staging 签发" "✅  ${issuer}"
fi

# 5. 剩余有效期。这条记录三个环境共用, 快到期的不该写进去。
not_after="$(openssl x509 -in "${work}/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
epoch="$(date -u -d "${not_after}" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "${not_after}" +%s 2>/dev/null || echo 0)"
days_left=$(( (epoch - $(date -u +%s)) / 86400 ))
if [ "${epoch}" -eq 0 ]; then
  note "5. 剩余有效期" "❌ 无法解析到期时间"; fail=1
elif [ "${days_left}" -le 0 ]; then
  note "5. 剩余有效期" "❌ 已过期 ${days_left#-} 天"; fail=1
elif [ "${days_left}" -lt 14 ]; then
  note "5. 剩余有效期" "❌ 仅剩 ${days_left} 天(<14, 应先续期)"; fail=1
else
  note "5. 剩余有效期" "✅  ${days_left} 天 (至 ${not_after})"
fi

# 6. 链完整性: 叶证书要能被链里给出的 CA 验通。缺中间证书时浏览器多半仍能补全,
#    但 stunnel 这类严格校验的消费方会直接失败。
if [ -s "${work}/ca.pem" ] && openssl verify -partial_chain -CAfile "${work}/ca.pem" "${work}/cert.pem" >/dev/null 2>&1; then
  note "6. 链完整(叶←CA)" "✅"
elif [ ! -s "${work}/ca.pem" ]; then
  note "6. 链完整(叶←CA)" "❌ fullchain 里没有中间证书"; fail=1
else
  note "6. 链完整(叶←CA)" "❌ 验证失败"; fail=1
fi

if [ "${fail}" -ne 0 ]; then
  echo >&2
  echo "拒绝写入: 上面有未通过项。这条记录 sit/uat/prod 共用, 写进坏证书会让三个环境一起坏。" >&2
  exit 1
fi

if [ "${DRY_RUN}" = true ]; then
  echo ">> --dry-run: 校验全部通过, 未写入。"
  exit 0
fi

# ------------------------------------------------- 合并现有记录后整条写回
echo ">> 读取现有记录以便合并(kv v2 写入是整条替换, 不合并会清空其它字段)..."
cur_http="$(curl -sS -o "${work}/cur.json" -w '%{http_code}' \
  -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR%/}/v1/${VAULT_PATH}" || echo 000)"
if [ "${cur_http}" = "200" ]; then
  jq '.data.data // {}' "${work}/cur.json" > "${work}/base.json"
elif [ "${cur_http}" = "404" ]; then
  echo "{}" > "${work}/base.json"
  echo "   (该路径尚不存在, 将新建)"
else
  echo "错误: 读取现有记录返回 HTTP ${cur_http}; 中止, 以免整条覆盖掉看不见的字段。" >&2
  exit 1
fi

if [ -n "${TRUST_BUNDLE}" ]; then
  tb_b64="$(base64 < "${TRUST_BUNDLE}" | tr -d '\n')"
else
  # 运维自己维护的字段, 没显式给就原样保留 —— 它不是 Caddy 产出的, 丢了
  # stunnel 客户端校验会失败。
  tb_b64="$(jq -r '.tls_trust_bundle_pem_b64 // empty' "${work}/base.json")"
  [ -n "${tb_b64}" ] && echo "   保留现有 tls_trust_bundle_pem_b64" \
                     || echo "   ::warning:: 现有记录没有 tls_trust_bundle_pem_b64, 且未通过 --trust-bundle 提供"
fi

b64() { base64 < "$1" | tr -d '\n'; }

jq -n \
  --argjson base "$(cat "${work}/base.json")" \
  --arg fullchain "$(b64 "${work}/fullchain.pem")" \
  --arg cert      "$(b64 "${work}/cert.pem")" \
  --arg key       "$(b64 "${work}/key.pem")" \
  --arg ca        "$(b64 "${work}/ca.pem")" \
  --arg tb        "${tb_b64}" \
  --arg na        "${epoch}" \
  --arg dom       "*.${DOMAIN} ${DOMAIN}" \
  --arg at        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg src       "${FROM_HOST:-manual-upload}" \
  '{data: ($base + {
      tls_fullchain_pem_b64:    $fullchain,
      tls_cert_pem_b64:         $cert,
      tls_key_pem_b64:          $key,
      tls_ca_pem_b64:           $ca,
      tls_trust_bundle_pem_b64: $tb,
      not_after_epoch:          $na,
      domains:                  $dom,
      backed_up_at:             $at,
      source_host:              $src
    })}' > "${work}/body.json"

http="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  --data-binary @"${work}/body.json" \
  "${VAULT_ADDR%/}/v1/${VAULT_PATH}" || echo 000)"

case "${http}" in
  200|204)
    echo ">> ✅ 已写入 ${VAULT_PATH}"
    echo "   域名:   *.${DOMAIN} ${DOMAIN}"
    echo "   有效期: 还有 ${days_left} 天 (至 ${not_after})"
    echo "   签发方: ${issuer}"
    echo
    echo "   下一次部署的 restore 会直接复用它, 不再调用 ACME。"
    ;;
  *)
    echo "错误: 写入返回 HTTP ${http}" >&2; exit 1 ;;
esac
