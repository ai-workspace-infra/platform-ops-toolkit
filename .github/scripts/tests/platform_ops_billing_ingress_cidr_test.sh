#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
resolver="${repo_root}/.github/scripts/platform-ops/deploy/platform-ops_deploy_base_resolve-billing-agent-cidrs.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

write_fixture() {
  local path="$1"
  mkdir -p "$(dirname "${path}")"
  cat >"${path}"
}

fake_bin="${tmp_dir}/bin"
mkdir -p "${fake_bin}"
write_fixture "${fake_bin}/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${2:-}" in
  jp-xconnect.svc.plus) printf '%s\n' '35.79.83.48 STREAM jp-xconnect.svc.plus' '35.79.83.48 DGRAM jp-xconnect.svc.plus' ;;
  us-xconnect.svc.plus) printf '%s\n' '34.216.156.87 STREAM us-xconnect.svc.plus' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "${fake_bin}/getent"

resource_dir="${tmp_dir}/gitops/resources"
write_fixture "${resource_dir}/agent-proxy-jp.yaml" <<'EOF'
hosts:
  - name: jpn-tky
    host_vars:
      service_domains: [jp-xconnect.svc.plus]
EOF
write_fixture "${resource_dir}/agent-proxy-us.yaml" <<'EOF'
hosts:
  - name: us-ca
    host_vars:
      service_domains: [us-xconnect.svc.plus]
EOF

cmdb="${tmp_dir}/cmdb.json"
printf '{}\n' >"${cmdb}"
github_env="${tmp_dir}/github.env"
PATH="${fake_bin}:${PATH}" GITOPS_AGENT_PROXY_RESOURCE_DIR="${resource_dir}" CMDB_FILE="${cmdb}" GITHUB_ENV="${github_env}" \
  "${resolver}"
grep -Fqx 'WEB_SAAS_BILLING_ALLOWED_CIDRS=34.216.156.87/32 35.79.83.48/32' "${github_env}"

cmdb_with_agent="${tmp_dir}/cmdb-with-agent.json"
cat >"${cmdb_with_agent}" <<'EOF'
{
  "jp-xconnect.svc.plus": {"groups": ["agent_proxy"], "ip": "192.0.2.7"}
}
EOF
github_env="${tmp_dir}/github-cmdb.env"
PATH="${fake_bin}:${PATH}" GITOPS_AGENT_PROXY_RESOURCE_DIR="${resource_dir}" CMDB_FILE="${cmdb_with_agent}" GITHUB_ENV="${github_env}" \
  "${resolver}"
grep -Fqx 'WEB_SAAS_BILLING_ALLOWED_CIDRS=192.0.2.7/32' "${github_env}"

override_env="${tmp_dir}/github-override.env"
DEPLOY_ENV=uat BILLING_AGENT_PROXY_CIDRS_OVERRIDE='172.237.1.168/32 2001:db8::/64' CMDB_FILE="${cmdb}" GITHUB_ENV="${override_env}" \
  "${resolver}"
grep -Fqx 'WEB_SAAS_BILLING_ALLOWED_CIDRS=172.237.1.168/32 2001:db8::/64' "${override_env}"

if DEPLOY_ENV=prod BILLING_AGENT_PROXY_CIDRS_OVERRIDE='192.0.2.7/32' CMDB_FILE="${cmdb}" GITHUB_ENV="${tmp_dir}/github-prod-override.env" \
  "${resolver}"; then
  echo "expected production CIDR override to fail" >&2
  exit 1
fi

echo "billing ingress CIDR resolver tests passed"
