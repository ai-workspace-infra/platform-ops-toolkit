#!/usr/bin/env bash
#==============================================================#
# File      :   2026-07-30-verify-vault-tls-cert.sh            #
# Desc      :   Verify TLS certificates stored in Vault        #
# Usage     :   ./2026-07-30-verify-vault-tls-cert.sh <domain> [vault_token] [vault_addr]
#==============================================================#

set -eo pipefail

DOMAIN=$1
TOKEN=$2
ADDR=$3

if [[ -z "$DOMAIN" ]]; then
    echo "错误: 未提供域名参数。"
    echo "用法: $0 <DOMAIN> [VAULT_TOKEN] [VAULT_ADDR]"
    echo "示例: $0 onwalk.net"
    exit 1
fi

export VAULT_TOKEN="${TOKEN:-$VAULT_TOKEN}"
export VAULT_ADDR="${ADDR:-${VAULT_ADDR:-https://vault.svc.plus}}"

if [[ -z "$VAULT_TOKEN" ]]; then
    echo "错误: 未在环境中找到 VAULT_TOKEN，且未作为参数传入。"
    echo "请提供 Vault 访问凭证。"
    exit 1
fi

if ! command -v vault &> /dev/null; then
    echo "错误: 找不到 vault 命令行工具，请先安装。"
    exit 1
fi

if ! command -v openssl &> /dev/null; then
    echo "错误: 找不到 openssl 命令行工具，请先安装。"
    exit 1
fi

echo "========================================================="
echo ">> 开始验证 Vault 中存储的证书信息..."
echo ">> 目标域名: $DOMAIN"
echo ">> Vault地址: $VAULT_ADDR"
echo "========================================================="

echo ">> 1. 正在从 Vault (kv/CICD/domains/$DOMAIN) 拉取证书..."
# 获取证书的 base64 并解码
CERT_B64=$(vault kv get -field=tls_cert_pem_b64 kv/CICD/domains/"$DOMAIN" 2>/dev/null || true)

if [[ -z "$CERT_B64" ]]; then
    echo "错误: 无法从 Vault 读取证书，或证书字段不存在。请检查 Token 权限或目标路径。"
    exit 1
fi

echo ">> 2. 解析证书详情..."
echo "---------------------------------------------------------"

echo "$CERT_B64" | base64 -d | openssl x509 -text -noout | grep -E "Issuer:|Validity|Not Before|Not After|Subject:|DNS:"

echo "---------------------------------------------------------"
echo ">> 验证完成！"
