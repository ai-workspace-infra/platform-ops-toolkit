#!/usr/bin/env bash
set -euo pipefail

: "${CMDB_FILE:?CMDB_FILE is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

# A Web SaaS deployment may live in a separate Terraform/CMDB state from the
# regional Agent Proxy nodes (the UAT Akamai layout does this deliberately).
# In that case the current CMDB cannot contain an agent_proxy group.  The
# platform workflow passes the checked-out GitOps resource directory so this
# script can resolve only the declared Agent Proxy service names.  This keeps
# the ingress fail-closed while avoiding a hard-coded public IP list.
agent_proxy_resource_dir="${GITOPS_AGENT_PROXY_RESOURCE_DIR:-}"
getent_bin="${GETENT_BIN:-getent}"

if [[ ! -s "${CMDB_FILE}" ]]; then
  echo "::error::CMDB file is empty: ${CMDB_FILE}" >&2
  exit 1
fi

mapfile -t agent_ips < <(
  jq -r '
    to_entries[]
    | select((.value.groups // []) | index("agent_proxy"))
    | (.value.ip // .value.ansible_host // empty)
    | select(test("^[0-9a-fA-F:.]+$"))
  ' "${CMDB_FILE}"
)

if ((${#agent_ips[@]} == 0)) && [[ -n "${agent_proxy_resource_dir}" ]]; then
  if [[ ! -d "${agent_proxy_resource_dir}" ]]; then
    echo "::error::GitOps Agent Proxy resource directory does not exist: ${agent_proxy_resource_dir}" >&2
    exit 1
  fi

  mapfile -t agent_proxy_hosts < <(
    python3 - "${agent_proxy_resource_dir}" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:
    raise SystemExit(f"PyYAML is required to read GitOps Agent Proxy resources: {exc}")

resource_dir = Path(sys.argv[1])
for path in sorted(resource_dir.glob("agent-proxy*.yaml")):
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    for host in document.get("hosts", []) or []:
        service_domains = (host.get("host_vars") or {}).get("service_domains") or []
        if isinstance(service_domains, str):
            service_domains = [service_domains]
        for service_domain in service_domains:
            value = str(service_domain).strip()
            if value:
                print(value)
PY
  )

  resolved_agent_ips=()
  unresolved_agent_hosts=()
  for host in "${agent_proxy_hosts[@]}"; do
    # Resource declarations must contain DNS names, never an arbitrary shell
    # fragment or a wildcard.  IP literals are also intentionally rejected so
    # the source remains the reviewed GitOps declaration.
    if [[ ! "${host}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ || "${host}" != *.* ]]; then
      echo "::error::Invalid Agent Proxy service domain in GitOps resource: ${host}" >&2
      exit 1
    fi
    mapfile -t host_ips < <("${getent_bin}" ahosts "${host}" 2>/dev/null | awk '{print $1}' | sort -u)
    if ((${#host_ips[@]} == 0)); then
      unresolved_agent_hosts+=("${host}")
      continue
    fi
    resolved_agent_ips+=("${host_ips[@]}")
  done

  if ((${#resolved_agent_ips[@]} > 0)); then
    mapfile -t agent_ips < <(printf '%s\n' "${resolved_agent_ips[@]}" | sort -u)
    echo "Resolved GitOps Agent Proxy service domains to source addresses: ${agent_ips[*]}"
  fi
  if ((${#unresolved_agent_hosts[@]} > 0)); then
    echo "::warning::GitOps Agent Proxy service domains did not resolve and were excluded: ${unresolved_agent_hosts[*]}" >&2
  fi
fi

if ((${#agent_ips[@]} == 0)); then
  echo "No Agent Proxy source address is available; Billing Caddy ingress stays disabled."
  echo "WEB_SAAS_BILLING_ALLOWED_CIDRS=" >> "${GITHUB_ENV}"
  exit 0
fi

cidrs=()
for ip in "${agent_ips[@]}"; do
  if [[ "${ip}" == *:* ]]; then
    cidrs+=("[${ip}]/128")
  elif [[ "${ip}" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    cidrs+=("${ip}/32")
  else
    echo "::error::Resolved Agent Proxy address is not an IPv4 or IPv6 literal: ${ip}" >&2
    exit 1
  fi
done

allowed_cidrs="$(IFS=' '; echo "${cidrs[*]}")"
echo "WEB_SAAS_BILLING_ALLOWED_CIDRS=${allowed_cidrs}" >> "${GITHUB_ENV}"
echo "Billing Caddy ingress will allow agent-proxy CIDRs: ${allowed_cidrs}"
