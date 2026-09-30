#!/usr/bin/env bash
set -euo pipefail

: "${DOMAIN:?DOMAIN is required}"
: "${SERVICE_STAGE:?SERVICE_STAGE is required}"

verify() {
  local body
  body="$(curl --fail --silent --show-error --retry 6 --retry-all-errors --retry-delay 5 \
    --connect-timeout 5 --max-time 20 "https://${DOMAIN}/.well-known/openid-configuration")"
  jq -e --arg issuer "https://${DOMAIN}" \
    '.issuer == $issuer and (.jwks_uri | startswith($issuer + "/"))' <<<"${body}" >/dev/null
  echo "ZITADEL OIDC discovery verified for ${DOMAIN}"
}

if [[ "${SERVICE_STAGE}" == verify ]]; then
  verify
  exit 0
fi
[[ "${SERVICE_STAGE}" == deploy ]] || { echo 'Unsupported service stage' >&2; exit 2; }
: "${PROJECT_ID:?}" "${AUTH_PROJECT_ID:?}" "${NODE_NAME:?}" "${NODE_ZONE:?}" "${NETWORK_NAME:?}"
: "${ZITADEL_MASTERKEY:?}" "${ZITADEL_ADMIN_PASSWORD:?}" "${ZITADEL_PG_PASSWORD:?}" "${POSTGRESQL_ADMIN_PASSWORD:?}" "${VAULT_TOKEN:?}"
: "${ZITADEL_GITOPS_SHA:?}" "${ZITADEL_GITOPS_URL:?}" "${ZITADEL_DOCO_CD_IMAGE:?}"
: "${ZITADEL_IMAGE:?}" "${ZITADEL_LOGIN_IMAGE:?}" "${ZITADEL_LOGIN_SESSION_COOKIE_SECRET:?}"
[[ "${AUTH_PROJECT_ID}" == "${PROJECT_ID}" ]] || { echo 'Vault GCP identity does not match GitOps project' >&2; exit 1; }
[[ "${#ZITADEL_MASTERKEY}" == 32 && "${ZITADEL_MASTERKEY}" != MasterkeyNeedsToHave32Characters ]] || {
  echo 'Vault must contain a non-placeholder 32-character ZITADEL masterkey' >&2; exit 1;
}
[[ -f playbooks/deploy_zitadel_docker.yaml ]] || { echo 'Requested ZITADEL playbook is missing' >&2; exit 1; }

instance="$(gcloud compute instances describe "${NODE_NAME}" --project="${PROJECT_ID}" --zone="${NODE_ZONE}" --format=json)"
[[ "$(jq -r .status <<<"${instance}")" == RUNNING ]] || { echo 'IAM VM is not RUNNING' >&2; exit 1; }
target_ip="$(jq -er '[.networkInterfaces[]?.accessConfigs[]?.natIP // empty] | first' <<<"${instance}")"
target_tags="$(jq -er '.tags.items | select(length > 0) | join(",")' <<<"${instance}")"
python3 - "${target_ip}" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
# ACME requires the declared public domain to resolve to this exact VM.
python3 - "${DOMAIN}" "${target_ip}" <<'PY'
import socket, sys
addresses = {item[4][0] for item in socket.getaddrinfo(sys.argv[1], 443, socket.AF_INET)}
if addresses != {sys.argv[2]}:
    raise SystemExit("IAM DNS must point exclusively to the declared VM before deployment")
PY

access_dir="$(mktemp -d "${RUNNER_TEMP:?}/zitadel-access.XXXXXX")"
rule="zitadel-ssh-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
cleanup() {
  local result=$?
  trap - EXIT
  if gcloud compute firewall-rules describe "${rule}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    gcloud compute firewall-rules delete "${rule}" --project="${PROJECT_ID}" --quiet || result=1
  fi
  if [[ -f "${access_dir}/id_ed25519.pub" ]]; then
    gcloud compute os-login ssh-keys remove --project="${PROJECT_ID}" --key-file="${access_dir}/id_ed25519.pub" || result=1
  fi
  rm -rf -- "${access_dir}"
  exit "${result}"
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "${access_dir}/id_ed25519"
gcloud compute os-login ssh-keys add --project="${PROJECT_ID}" --key-file="${access_dir}/id_ed25519.pub" --ttl=20m >/dev/null
profile="$(gcloud compute os-login describe-profile --project="${PROJECT_ID}" --format=json)"
ssh_user="$(jq -er '[.posixAccounts[]? | select(.operatingSystemType == "LINUX") | .username] | first' <<<"${profile}")"
[[ "${ssh_user}" =~ ^[a-z_][a-z0-9_-]{0,31}\$?$ ]] || exit 1
runner_ip="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 15 https://api.ipify.org)"
python3 - "${runner_ip}" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
gcloud compute firewall-rules create "${rule}" --project="${PROJECT_ID}" --network="${NETWORK_NAME}" \
  --direction=INGRESS --priority=1000 --action=ALLOW --rules=tcp:22 \
  --source-ranges="${runner_ip}/32" --target-tags="${target_tags}" --quiet
export ACCESS_DIR="${access_dir}" TARGET_IP="${target_ip}" SSH_USER="${ssh_user}"
python3 - <<'PY'
import json, os
from pathlib import Path
p = Path(os.environ["ACCESS_DIR"])
host = os.environ["NODE_NAME"]
vars = {"ansible_host": os.environ["TARGET_IP"], "ansible_user": os.environ["SSH_USER"],
        "ansible_ssh_private_key_file": str(p / "id_ed25519"),
        "ansible_ssh_common_args": f"-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile={p}/known_hosts"}
(p / "inventory.json").write_text(json.dumps({"all": {"hosts": {host: vars}}}))
extra = {"domain": os.environ["DOMAIN"], "zitadel_domain": os.environ["DOMAIN"],
         "zitadel_deployment_mode": "doco-cd",
         "zitadel_masterkey": os.environ["ZITADEL_MASTERKEY"],
         "zitadel_admin_password": os.environ["ZITADEL_ADMIN_PASSWORD"],
         "db_configs_raw": [{"db": "zitadel", "user": "zitadel_user",
                             "env_var": "ZITADEL_PG_PASSWORD", "vault_key": "zitadel_pg_password"}]}
(p / "extra.json").write_text(json.dumps(extra))
(p / "extra.json").chmod(0o600)
PY
python3 -m pip install --disable-pip-version-check --quiet ansible hvac psycopg2-binary
ansible-galaxy collection install community.hashi_vault community.postgresql community.docker
ping_output="$(ansible -i "${access_dir}/inventory.json" all --limit "${NODE_NAME}" -b -m ping)"
grep -Fq 'SUCCESS' <<<"${ping_output}" || { echo 'IAM host did not match a reachable inventory target' >&2; exit 1; }
export POSTGRESQL_DEPLOY_MODE=compose POSTGRESQL_CONTAINER_NAME=postgresql-svc-plus
export WEB_SAAS_POSTGRES_PASSWORD="${POSTGRESQL_ADMIN_PASSWORD}"
export ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD="${POSTGRESQL_ADMIN_PASSWORD}"
export OPEN_PLATFORM_DEPLOY_ONLY=false
# The existing IAM wrapper owns PostgreSQL setup and imports the requested
# deploy_zitadel_docker.yaml. Limit it to the single fresh cloud-side identity.
(
  cd playbooks
  ansible-playbook -i "${access_dir}/inventory.json" deploy_iam_domain.yml \
    --limit "${NODE_NAME}" -e "@${access_dir}/extra.json"
)
verify
printf '### ZITADEL server\n\n- Project: `%s`\n- Node: `%s`\n- Domain: `%s`\n- OIDC discovery: passed\n' \
  "${PROJECT_ID}" "${NODE_NAME}" "${DOMAIN}" >> "${GITHUB_STEP_SUMMARY}"
