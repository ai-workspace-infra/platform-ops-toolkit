#!/usr/bin/env bash
set -euo pipefail

: "${EXISTING_TARGET_HOST:?EXISTING_TARGET_HOST is required}"
: "${EXISTING_TARGET_USER:?EXISTING_TARGET_USER is required}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"

mkdir -p "${OUTPUT_DIR}"

python3 - "${OUTPUT_DIR}" "${EXISTING_TARGET_HOST}" "${EXISTING_TARGET_USER}" <<'PY'
import ipaddress
import json
import re
import sys
from pathlib import Path

output_dir, host, user = sys.argv[1:]
if any(char.isspace() for char in host) or any(char.isspace() for char in user):
    raise SystemExit("existing host and user must not contain whitespace")
if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}\$?", user):
    raise SystemExit("existing user must be a POSIX account name")
try:
    ipaddress.ip_address(host)
except ValueError:
    if not re.fullmatch(r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*", host):
        raise SystemExit("existing host must be an IP address or hostname")

record = {
    "name": "ai-workspace-existing-uat",
    "fqdn": host,
    "ip": host,
    "instance_id": "external-existing-ai-workspace-uat",
    "os_name": "existing",
    "plan": "4C8G",
    "region": "xconnect-private",
    "ansible_user": user,
    "groups": ["ai_workspace", "debian", "database"],
    "tags": ["existing", "xconnect", "ai_workspace"],
    "host_vars": {
        "role": "primary",
        "management_mode": "existing",
        "provider": "gcp-cloud",
        "xconnect_required": True,
        "service_domains": ["ai-workspace.onwalk.net", "postgresql-ai-workspace.onwalk.net"],
        "plan": "4C8G",
        "region": "xconnect-private",
    },
}
cmdb = {host: record}
(Path(output_dir) / "cmdb.json").write_text(json.dumps(cmdb, indent=2) + "\n", encoding="utf-8")
(Path(output_dir) / "hosts_manifest.json").write_text(
    json.dumps({"management_mode": "existing", "provider": "gcp-cloud", "hosts": [record]}, indent=2) + "\n",
    encoding="utf-8",
)

inventory = "\n".join(
    [
        "# Generated for an existing AI Workspace host; Terraform is not involved.",
        "[ai_workspace]",
        f"{host} ansible_host={host} ansible_user={user} management_mode=existing provider=gcp-cloud",
        "[debian]",
        host,
        "[database]",
        host,
        "",
    ]
)
(Path(output_dir) / "inventory.ini").write_text(inventory, encoding="utf-8")
PY

echo "Rendered existing-host CMDB for ${EXISTING_TARGET_HOST} (no Terraform state)."
