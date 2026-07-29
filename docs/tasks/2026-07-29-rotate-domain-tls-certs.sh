#!/usr/bin/env bash
# 定期生成并覆盖 Vault 中的泛域名自签证书 (包含 CA、服务端证书与私钥)。
#
# 用法:
#   ./docs/tasks/2026-07-29-rotate-domain-tls-certs.sh <VAULT_TOKEN>
#
# 建议的 Crontab 配置 (每两个月/约60天的1号凌晨2点执行):
#   0 2 1 */2 * /absolute/path/to/2026-07-29-rotate-domain-tls-certs.sh "hvs.xxxxxxxxx" >> /var/log/rotate-tls.log 2>&1

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "错误: 请提供 Vault 管理员 Token 作为第一个参数。"
    echo "用法: $0 <VAULT_TOKEN>"
    exit 1
fi

export VAULT_TOKEN="$1"
export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"

DOMAINS=("onwalk.net" "svc.plus" "xworkmate.com")

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

for DOMAIN in "${DOMAINS[@]}"; do
  echo "==> [$(date -u +%Y-%m-%dT%H:%M:%SZ)] 生成证书: $DOMAIN"
  
  # 1. 创建自签 Root CA (有效期 10 年)
  openssl genrsa -out "${workdir}/ca.key" 2048 2>/dev/null
  openssl req -x509 -new -nodes -key "${workdir}/ca.key" -sha256 -days 3650 -out "${workdir}/ca.crt" -subj "/CN=${DOMAIN} Root CA" 2>/dev/null
  
  # 2. 创建泛域名 (Server) 证书 (有效期 10 年)
  openssl genrsa -out "${workdir}/server.key" 2048 2>/dev/null
  openssl req -new -key "${workdir}/server.key" -out "${workdir}/server.csr" -subj "/CN=*.${DOMAIN}" 2>/dev/null
  
  cat > "${workdir}/ext.cnf" <<EOCNF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.${DOMAIN}
DNS.2 = ${DOMAIN}
EOCNF
  
  openssl x509 -req -in "${workdir}/server.csr" -CA "${workdir}/ca.crt" -CAkey "${workdir}/ca.key" -CAcreateserial -out "${workdir}/server.crt" -days 3650 -sha256 -extfile "${workdir}/ext.cnf" 2>/dev/null
  
  # 3. 准备 Base64 负载
  ca_b64=$(base64 -w0 < "${workdir}/ca.crt" || base64 < "${workdir}/ca.crt" | tr -d '\n')
  key_b64=$(base64 -w0 < "${workdir}/server.key" || base64 < "${workdir}/server.key" | tr -d '\n')
  cert_b64=$(base64 -w0 < "${workdir}/server.crt" || base64 < "${workdir}/server.crt" | tr -d '\n')
  fullchain_b64=$(cat "${workdir}/server.crt" "${workdir}/ca.crt" | base64 -w0 || cat "${workdir}/server.crt" "${workdir}/ca.crt" | base64 | tr -d '\n')
  
  # 默认在 Vault 里记 10 年。因为证书每次重建都会复用, 我们也可以只签短一点。
  not_after=$(date -d "+3650 days" +%s 2>/dev/null || date -v+3650d +%s)
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  # 4. 上传至 Vault KV
  echo "==> 上传至 kv/CICD/domains/$DOMAIN"
  
  vault kv put "kv/CICD/domains/$DOMAIN" \
    caddy_data_tar_b64="" \
    tls_fullchain_pem_b64="$fullchain_b64" \
    tls_cert_pem_b64="$cert_b64" \
    tls_key_pem_b64="$key_b64" \
    tls_ca_pem_b64="$ca_b64" \
    tls_trust_bundle_pem_b64="$ca_b64" \
    domains="*.${DOMAIN} ${DOMAIN}" \
    not_after_epoch="$not_after" \
    source_host="cron_rotate_script" \
    backed_up_at="$now" >/dev/null

done

echo "==> 所有证书已成功轮转并上传至 Vault。"
