#!/usr/bin/env bash
# 定期生成并覆盖 Vault 中的泛域名证书。
# 默认使用 ACME DNS-01 (Let's Encrypt 90天) 获取真实受信任的证书；
# 当缺少 Cloudflare API Token 或 ACME 失败时，回退到内部自签名证书。
#
# 用法:
#   export CLOUDFLARE_DNS_API_TOKEN="cfat_xxx" (可选，用于 ACME)
#   ./docs/tasks/2026-07-29-rotate-domain-tls-certs.sh <VAULT_TOKEN>
#
# 建议的 Crontab 配置 (每两个月/约60天的1号凌晨2点执行):
#   0 2 1 */2 * CLOUDFLARE_DNS_API_TOKEN="xxx" /path/to/2026-07-29-rotate-domain-tls-certs.sh "hvs.xxxxxxxxx" >> /var/log/rotate-tls.log 2>&1

set -euo pipefail

if [ -z "${VAULT_TOKEN:-}" ] && [ $# -ge 1 ]; then
    export VAULT_TOKEN="$1"
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
    echo "错误: 未在环境中找到 VAULT_TOKEN，且未作为参数传入。"
    echo "用法 (手动执行): $0 <VAULT_TOKEN>"
    echo "用法 (CI 执行): 依赖 vault-action 注入的 VAULT_TOKEN 环境变量即可，无需参数。"
    exit 1
fi
export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"

DOMAINS=("onwalk.net" "svc.plus" "xworkmate.com")

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

has_docker() {
  command -v docker >/dev/null 2>&1
}

for DOMAIN in "${DOMAINS[@]}"; do
  echo "==> [$(date -u +%Y-%m-%dT%H:%M:%SZ)] 生成证书: $DOMAIN"
  
  acme_success=false
  
  if [ -n "${CLOUDFLARE_DNS_API_TOKEN:-}" ] && has_docker; then
    echo "  -> 检测到 CLOUDFLARE_DNS_API_TOKEN，尝试通过 Certbot(ACME DNS-01) 申请 Let's Encrypt 证书..."
    
    cat > "${workdir}/cloudflare.ini" <<EOCF
dns_cloudflare_api_token = ${CLOUDFLARE_DNS_API_TOKEN}
EOCF
    chmod 600 "${workdir}/cloudflare.ini"
    
    # 运行 Certbot
    certbot_ret=0
    docker run --rm \
      -v "${workdir}/letsencrypt:/etc/letsencrypt" \
      -v "${workdir}/letsencrypt-lib:/var/lib/letsencrypt" \
      -v "${workdir}/letsencrypt-log:/var/log/letsencrypt" \
      -v "${workdir}/cloudflare.ini:/cloudflare.ini:ro" \
      certbot/dns-cloudflare certonly \
      --dns-cloudflare \
      --dns-cloudflare-credentials /cloudflare.ini \
      --dns-cloudflare-propagation-seconds 20 \
      -d "${DOMAIN}" -d "*.${DOMAIN}" \
      --email "admin@${DOMAIN}" \
      --agree-tos --no-eff-email --non-interactive || certbot_ret=$?

    # 恢复文件权限 (Certbot 运行在 root 用户下)
    docker run --rm -v "${workdir}:/workdir" busybox chown -R "$(id -u):$(id -g)" /workdir

    if [ $certbot_ret -eq 0 ]; then
        echo "  -> ACME 证书申请成功！"
        live_dir="${workdir}/letsencrypt/live/${DOMAIN}"
        
        # Certbot 文件: 
        # cert.pem (叶子), chain.pem (CA链), fullchain.pem (叶子+CA链), privkey.pem (私钥)
        ca_b64=$(base64 -w0 < "${live_dir}/chain.pem" || base64 < "${live_dir}/chain.pem" | tr -d '\n')
        key_b64=$(base64 -w0 < "${live_dir}/privkey.pem" || base64 < "${live_dir}/privkey.pem" | tr -d '\n')
        cert_b64=$(base64 -w0 < "${live_dir}/cert.pem" || base64 < "${live_dir}/cert.pem" | tr -d '\n')
        fullchain_b64=$(base64 -w0 < "${live_dir}/fullchain.pem" || base64 < "${live_dir}/fullchain.pem" | tr -d '\n')
        
        # Let's Encrypt 证书有效期是 90 天
        not_after=$(date -d "+90 days" +%s 2>/dev/null || date -v+90d +%s)
        acme_success=true
    else
        echo "  -> [警告] ACME 申请失败，将回退到自签证书模式。"
    fi
  fi
  
  if [ "$acme_success" = false ]; then
    echo "  -> 使用自签模式 (Fallback) 生成内部证书..."
    
    openssl genrsa -out "${workdir}/ca.key" 2048 2>/dev/null
    openssl req -x509 -new -nodes -key "${workdir}/ca.key" -sha256 -days 3650 -out "${workdir}/ca.crt" -subj "/CN=${DOMAIN} Root CA" 2>/dev/null
    
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
    
    ca_b64=$(base64 -w0 < "${workdir}/ca.crt" || base64 < "${workdir}/ca.crt" | tr -d '\n')
    key_b64=$(base64 -w0 < "${workdir}/server.key" || base64 < "${workdir}/server.key" | tr -d '\n')
    cert_b64=$(base64 -w0 < "${workdir}/server.crt" || base64 < "${workdir}/server.crt" | tr -d '\n')
    fullchain_b64=$(cat "${workdir}/server.crt" "${workdir}/ca.crt" | base64 -w0 || cat "${workdir}/server.crt" "${workdir}/ca.crt" | base64 | tr -d '\n')
    
    not_after=$(date -d "+3650 days" +%s 2>/dev/null || date -v+3650d +%s)
  fi
  
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  source_host="cron_rotate_script_acme"
  if [ "$acme_success" = false ]; then
    source_host="cron_rotate_script_selfsigned"
  fi
  
  # 4. 上传至 Vault KV
  echo "  -> 上传至 kv/CICD/domains/$DOMAIN"
  
  vault kv put "kv/CICD/domains/$DOMAIN" \
    caddy_data_tar_b64="" \
    tls_fullchain_pem_b64="$fullchain_b64" \
    tls_cert_pem_b64="$cert_b64" \
    tls_key_pem_b64="$key_b64" \
    tls_ca_pem_b64="$ca_b64" \
    tls_trust_bundle_pem_b64="$ca_b64" \
    domains="*.${DOMAIN} ${DOMAIN}" \
    not_after_epoch="$not_after" \
    source_host="$source_host" \
    backed_up_at="$now" >/dev/null

done

echo "==> 所有证书已成功轮转并上传至 Vault。"
