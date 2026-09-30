#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
probe="${repo_root}/.github/scripts/snapshots/check-shared-readiness.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat > "${workdir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
url="${@: -1}"
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    *) shift ;;
  esac
done
case "${url}" in
  */v1/sys/health*) printf '%s\n' '{"initialized":true,"sealed":false}' >"${output}" ;;
  */grafana/api/health) printf '%s\n' '{"database":"ok"}' >"${output}" ;;
  */.well-known/openid-configuration) printf '%s\n' '{"issuer":"https://iam.svc.plus"}' >"${output}" ;;
  *) exit 1 ;;
esac
printf '200'
EOF
chmod +x "${workdir}/curl"

PATH="${workdir}:${PATH}" \
SHARED_VAULT_ENDPOINT=https://vault.svc.plus \
SHARED_OBSERVABILITY_ENDPOINT=https://observability.svc.plus \
SHARED_IAM_ENDPOINT=https://iam.svc.plus \
SHARED_IAM_ISSUER=https://iam.svc.plus \
SHARED_READINESS_TIMEOUT_SECONDS=2 \
bash "${probe}" >/dev/null

if PATH="${workdir}:${PATH}" \
  SHARED_VAULT_ENDPOINT=https://vault.svc.plus \
  SHARED_OBSERVABILITY_ENDPOINT=https://observability.svc.plus \
  SHARED_IAM_ENDPOINT=https://iam.svc.plus \
  SHARED_IAM_ISSUER=https://wrong.example \
  SHARED_READINESS_TIMEOUT_SECONDS=2 \
  bash "${probe}" >/dev/null 2>&1; then
  echo 'readiness probe must reject an unexpected IAM issuer' >&2
  exit 1
fi

echo 'shared_readiness_probe_test: PASS'
