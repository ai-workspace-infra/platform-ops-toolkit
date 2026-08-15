#!/usr/bin/env bash
set -euo pipefail

# A failed TLS probe used to terminate the remote shell because it combines
# `set -e -o pipefail` with openssl's non-zero handshake exit. Verify that it
# now reaches the explicit NO_TLS_HANDSHAKE diagnostic instead.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/scripts/platform-ops_deploy_base_assert-caddy-uses-restored-cert.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/tls/current" "${workdir}/bin"
printf 'fixture certificate\n' >"${workdir}/tls/current/fullchain.pem"
printf 'fixture private key\n' >"${workdir}/tls/current/key.pem"
cat >"${workdir}/Caddyfile" <<EOF
tls ${workdir}/tls/current/fullchain.pem ${workdir}/tls/current/key.pem
EOF
cat >"${workdir}/cmdb.json" <<'EOF'
{"console-uat.onwalk.net":{"ip":"192.0.2.10"}}
EOF

cat >"${workdir}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
DOMAIN_TLS_DIR="${MOCK_TLS_DIR}" \
CADDYFILE="${MOCK_CADDYFILE}" \
SNI_HOST="console-uat.onwalk.net" \
bash -s
EOF

cat >"${workdir}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'caddy-container-id\n'
EOF

cat >"${workdir}/bin/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
exec "$@"
EOF

cat >"${workdir}/bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" -in "* ]]; then
  printf 'sha256 Fingerprint=AA:BB:CC\n'
  exit 0
fi

# Model a Caddy endpoint that accepts the connection but does not present a
# certificate. Both stages of the TLS pipeline return non-zero.
exit 1
EOF
chmod +x "${workdir}/bin/ssh" "${workdir}/bin/docker" "${workdir}/bin/timeout" "${workdir}/bin/openssl"

set +e
PATH="${workdir}/bin:${PATH}" \
MOCK_TLS_DIR="${workdir}/tls" \
MOCK_CADDYFILE="${workdir}/Caddyfile" \
MATRIX_HOST=console-uat.onwalk.net \
DOMAIN_TLS_DIR="${workdir}/tls" \
CMDB_FILE="${workdir}/cmdb.json" \
bash "${script}" >"${workdir}/output" 2>&1
exit_code=$?
set -e

[[ "${exit_code}" -eq 1 ]] || {
  echo "expected TLS diagnostic exit 1, got ${exit_code}" >&2
  cat "${workdir}/output" >&2
  exit 1
}
grep -Fq 'answered no TLS handshake on :443' "${workdir}/output"

echo "caddy_restored_cert_diagnostic_test: PASS"
