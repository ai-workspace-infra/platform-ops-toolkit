#!/usr/bin/env bash
# Web SaaS host scripts log in as the CMDB SSH user. GCP OS Login (and AWS)
# hosts reject root; their user has passwordless sudo.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
scripts=(
  .github/scripts/platform-ops/deploy/platform-ops_deploy_base_wait-for-web-saas-postgres.sh
  .github/scripts/platform-ops/deploy/platform-ops_deploy_base_assert-caddy-uses-restored-cert.sh
  .github/scripts/platform-ops/observe/platform-ops_observe_backup-caddy-certs.sh
  .github/scripts/platform-ops/observe/platform-ops_observe-web-saas-ingress.sh
  .github/scripts/platform-ops/observe/platform-ops_observe-web-saas-containers.sh
)
for script in "${scripts[@]}"; do
  grep -Fq 'lib/cmdb-ssh-login.sh' "${repo_root}/${script}" || { echo "${script} must resolve the CMDB SSH user" >&2; exit 1; }
  if grep -Fq 'root@' "${repo_root}/${script}"; then
    echo "${script} must not hard-code a root login" >&2
    exit 1
  fi
done

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
cat >"${workdir}/ssh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
printf '%s\n' "${args[*]: -2}" >>"${SSH_LOG}"
[[ "$*" == *"bash -s"* ]] && cat >/dev/null
printf 'running healthy\n'
FAKE
chmod +x "${workdir}/ssh"

run() {
  local cmdb="$1" log="$2"
  printf '%s' "${cmdb}" >"${workdir}/cmdb.json"
  : >"${log}"
  PATH="${workdir}:${PATH}" SSH_LOG="${log}" MATRIX_HOST=web-saas-uat CMDB_FILE="${workdir}/cmdb.json" \
    bash "${repo_root}/${scripts[0]}" >"${log}.out" 2>&1
}

run '{"web-saas-uat":{"ip":"192.0.2.10","ansible_user":"sa_123456789012345678901"}}' "${workdir}/oslogin.log"
grep -Fxq 'sa_123456789012345678901@192.0.2.10 sudo -n true' "${workdir}/oslogin.log" || { echo 'OS Login probe must check sudo as the CMDB user' >&2; exit 1; }
grep -Fxq 'sa_123456789012345678901@192.0.2.10 sudo -n bash -s' "${workdir}/oslogin.log" || { echo 'OS Login remote work must run through sudo -n' >&2; exit 1; }

run '{"web-saas-uat":{"ip":"192.0.2.10"}}' "${workdir}/root.log"
grep -Fxq 'root@192.0.2.10 true' "${workdir}/root.log" || { echo 'a host without ansible_user keeps the root login' >&2; exit 1; }
grep -Fxq 'root@192.0.2.10 bash -s' "${workdir}/root.log" || { echo 'root runs remote work without sudo' >&2; exit 1; }

if run '{"web-saas-uat":{"ip":"192.0.2.10","ansible_user":"root;id"}}' "${workdir}/bad.log"; then
  echo 'an invalid CMDB SSH user must be refused' >&2
  exit 1
fi
[[ ! -s "${workdir}/bad.log" ]] || { echo 'no SSH may be attempted with an invalid user' >&2; exit 1; }

echo 'web_saas_rootless_ssh_test: PASS'
