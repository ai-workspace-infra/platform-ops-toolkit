#!/usr/bin/env bash
set -euo pipefail

# Unit test the pre-DNS container gate without contacting a host.  It must
# accept running containers without checking a public port, and print Doco-CD
# diagnostics if a required container never appears.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/scripts/platform-ops/observe/platform-ops_observe-web-saas-containers.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/cmdb.json" <<'EOF'
{"console-uat.onwalk.net":{"ip":"192.0.2.10"}}
EOF

cat >"${workdir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${SSH_LOG}"

if [[ "$*" == *" true" ]]; then
  exit 0
fi
if [[ "${SSH_MODE}" == "missing" && "$*" == *"Doco-CD recent logs"* ]]; then
  printf 'simulated Doco-CD diagnostic output\n'
  exit 0
fi
if [[ "${SSH_MODE}" == "healthy" ]]; then
  cat <<'STATES'
web-saas-postgresql|running|healthy
web-saas-stunnel-server|running|healthy
web-saas-stunnel-client|running|healthy
web-saas-accounts|running|none
web-saas-xworkmate-bridge|running|none
web-saas-billing|running|none
web-saas-console|running|none
web-saas-caddy|running|none
STATES
else
  printf 'web-saas-caddy|missing|none\n'
fi
EOF
chmod +x "${workdir}/ssh"

PATH="${workdir}:${PATH}" \
SSH_LOG="${workdir}/healthy.log" \
SSH_MODE=healthy \
MATRIX_HOST=console-uat.onwalk.net \
CMDB_FILE="${workdir}/cmdb.json" \
bash "${script}" >"${workdir}/healthy.out"

grep -Fq 'public ingress will be verified after DNS reconciliation' "${workdir}/healthy.out"

set +e
PATH="${workdir}:${PATH}" \
SSH_LOG="${workdir}/failure.log" \
SSH_MODE=missing \
MATRIX_HOST=console-uat.onwalk.net \
CMDB_FILE="${workdir}/cmdb.json" \
WEB_SAAS_CONTAINER_READY_TIMEOUT_SECONDS=0 \
WEB_SAAS_CONTAINER_READY_POLL_SECONDS=0 \
bash "${script}" >"${workdir}/failure.out" 2>&1
exit_code=$?
set -e

[[ "${exit_code}" -eq 1 ]] || {
  echo "expected readiness timeout exit 1, got ${exit_code}" >&2
  exit 1
}
grep -Fq 'Doco-CD and Web SaaS container diagnostics' "${workdir}/failure.out"
grep -Fq 'simulated Doco-CD diagnostic output' "${workdir}/failure.out"
grep -Fq 'Doco-CD recent logs' "${workdir}/failure.log"

echo "web_saas_container_readiness_test: PASS"
