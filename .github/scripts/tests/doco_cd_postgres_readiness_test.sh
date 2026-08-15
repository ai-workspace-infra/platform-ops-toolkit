#!/usr/bin/env bash
set -euo pipefail

# Unit test the external readiness gate without contacting a host. The SSH stub
# models both the healthy path and a timeout that must emit Doco-CD diagnostics.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/scripts/platform-ops/deploy/platform-ops_deploy_base_wait-for-web-saas-postgres.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/cmdb.json" <<'EOF'
{"console-uat.onwalk.net":{"ip":"192.0.2.10"}}
EOF

cat >"${workdir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${SSH_LOG}"
if [[ "${SSH_MODE}" == "healthy" ]]; then
  printf 'running healthy\n'
elif [[ "$*" == *"Doco-CD recent logs"* ]]; then
  printf 'simulated Doco-CD diagnostic output\n'
else
  printf 'missing\n'
fi
EOF
chmod +x "${workdir}/ssh"

PATH="${workdir}:${PATH}" \
SSH_LOG="${workdir}/healthy.log" \
SSH_MODE=healthy \
MATRIX_HOST=console-uat.onwalk.net \
CMDB_FILE="${workdir}/cmdb.json" \
bash "${script}" >/dev/null

set +e
PATH="${workdir}:${PATH}" \
SSH_LOG="${workdir}/failure.log" \
SSH_MODE=missing \
MATRIX_HOST=console-uat.onwalk.net \
CMDB_FILE="${workdir}/cmdb.json" \
WEB_SAAS_POSTGRES_READY_TIMEOUT_SECONDS=0 \
WEB_SAAS_POSTGRES_READY_POLL_SECONDS=0 \
bash "${script}" >"${workdir}/failure.out" 2>&1
exit_code=$?
set -e

[[ "${exit_code}" -eq 1 ]] || {
  echo "expected readiness timeout exit 1, got ${exit_code}" >&2
  exit 1
}
grep -Fq 'Doco-CD and Web SaaS diagnostics' "${workdir}/failure.out"
grep -Fq 'simulated Doco-CD diagnostic output' "${workdir}/failure.out"
grep -Fq 'Doco-CD recent logs' "${workdir}/failure.log"

echo "doco_cd_postgres_readiness_test: PASS"
