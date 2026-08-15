#!/bin/bash
if [ "${INPUT_RUN_INFRASTRUCTURE}" = "true" ]; then
  INVENTORY_PATH="../cmdb/inventory.ini"
else
  INVENTORY_PATH="../platform-ops-toolkit/inventory.ini"
fi
cd playbooks

# 记录来源主机集合:
#   * 走本次 run 生成的 CMDB 时, 里面只有这次 provision 出来的主机, 所以用 'all'
#     —— 否则 playbook 会回落到 cloudflare_dns_default_source_hosts 里那四个写死的
#     生产主机模式(cn_front_host 等), 与 CMDB 的组名(web_saas/debian/database)
#     一个都匹配不上, 结果一条主机 A 记录都不会生成。
#   * 走仓库内静态 inventory 时保持默认, 那份 inventory 是全量生产清单, 只应发布
#     那四类主机。
if [ "${INPUT_RUN_INFRASTRUCTURE}" = "true" ]; then
  SOURCE_HOSTS_ARG=(-e '{"cloudflare_dns_source_hosts": ["all"]}')
else
  SOURCE_HOSTS_ARG=()
fi

# UAT service domains do not have production source-domain counterparts in
# CMDB. Render their names from the delivery parameters and resolve the
# address from the current web_saas inventory group; never hardcode a VPS IP.
DNS_SERVICE_NAMES="${DNS_SERVICE_NAMES:-console accounts billing}"
if [ -z "${DEPLOY_ENV:-}" ] || [ -z "${PROVISION_TARGET_DOMAIN_BASE:-}" ]; then
  echo "::error::DEPLOY_ENV and PROVISION_TARGET_DOMAIN_BASE are required for parameterized DNS aliases." >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required to render parameterized DNS aliases." >&2
  exit 1
fi

DNS_ALIAS_RECORDS_JSON="$(
  jq -cn \
    --arg env "${DEPLOY_ENV}" \
    --arg base "${PROVISION_TARGET_DOMAIN_BASE}" \
    --arg services "${DNS_SERVICE_NAMES}" \
    '[ $services | split(" ")[] | select(length > 0) |
       {name: (.+"-"+$env+"."+$base), source_group: "web_saas", ttl: 1, proxied: false} ]'
)"

ansible-playbook -i "$INVENTORY_PATH" update_site_dns.yml \
  -e "target_domain=${PROVISION_TARGET_DOMAIN_BASE}" \
  -e "source_domain=${PROVISION_SOURCE_DOMAIN_BASE}" \
  -e "cloudflare_dns_alias_records=${DNS_ALIAS_RECORDS_JSON}" \
  "${SOURCE_HOSTS_ARG[@]}"
