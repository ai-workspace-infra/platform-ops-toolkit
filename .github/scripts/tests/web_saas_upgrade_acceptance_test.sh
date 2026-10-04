#!/usr/bin/env bash
set -euo pipefail

# Unit test for the verify-side rules of platform-ops_web-saas-upgrade-acceptance.sh
# (running images, in-host HTTP probes, polling) and for the orchestrator wiring
# that makes the acceptance independent of DNS. No host or database is
# contacted: ssh answers with canned host output. The database half is covered
# against a real PostgreSQL by web_saas_upgrade_acceptance_postgres_test.sh.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/scripts/platform-ops/observe/platform-ops_web-saas-upgrade-acceptance.sh"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

printf '{"web-saas-uat":{"ip":"192.0.2.10","ansible_user":"debian"}}' >"${workdir}/cmdb.json"
TAG=uat-daily-build-2026.10.04-r1

# ssh: `true` succeeds unless SSH_DOWN; probe answers PROBE_<n> (n = call
# number, falling back to PROBE); compare answers the healthy comparison.
cat >"${workdir}/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${!#}"
echo "${cmd}" >>"${SSH_LOG}"
[[ -n "${SSH_DOWN:-}" ]] && { echo "ssh: connect to host 192.0.2.10 port 22: Connection refused" >&2; exit 255; }
[[ "${cmd}" == *" true" ]] && exit 0
cat >/dev/null
case "${cmd}" in
  *"-- probe "*)
    n=$(( $(cat "${SSH_LOG}.probe" 2>/dev/null || echo 0) + 1 )); echo "${n}" >"${SSH_LOG}.probe"
    var="PROBE_${n}"; printf '%b\n' "${!var:-${PROBE}}" ;;
  *"-- compare "*)
    printf '%b\n' "baseline_state=present\nbaseline_migration=2026092801:false\nbaseline_users_with_password=2\nbaseline_rows_users=2\nbaseline_rows_identities=0\nbaseline_rows_subscriptions=1\npost_db=present\npost_migration=2026092801:false\npost_users_with_password=2\ntable users before=2 after=2 missing=0 changed=0 dropped_columns=0\ntable identities before=0 after=0 missing=0 changed=0 dropped_columns=0\ntable subscriptions before=1 after=1 missing=0 changed=0 dropped_columns=0" ;;
  *"-- baseline "*)
    n=$(( $(cat "${SSH_LOG}.baseline" 2>/dev/null || echo 0) + 1 )); echo "${n}" >"${SSH_LOG}.baseline"
    (( n > ${BASELINE_FAILS:-0} )) || { echo "psql: server closed the connection unexpectedly" >&2; exit 2; }
    echo "baseline=captured"; echo "state=present" ;;
esac
EOF
chmod +x "${workdir}/ssh"

probe() { # <accounts-tag> <readyz> <console-status> [console-image]
  local console="${4:-ghcr.io/ai-workspace-services/console:$1}"
  printf '%s' "image web-saas-accounts ghcr.io/ai-workspace-services/accounts:$1 ghcr.io/ai-workspace-services/accounts@sha256:aa\nimage web-saas-console ${console} none\nimage web-saas-billing ghcr.io/ai-workspace-services/billing-service:$1 none\nhttp accounts_readyz $2\nhttp accounts_ping 200\nhttp console_root $3"
}

pass=0
run() { # <mode> [env...]
  local mode="$1"; shift
  rm -f "${workdir}"/ssh.log*
  rc=0
  out="$(env PATH="${workdir}:${PATH}" SSH_LOG="${workdir}/ssh.log" MATRIX_HOST=web-saas-uat \
    CMDB_FILE="${workdir}/cmdb.json" ACCEPTANCE_RUN_ID=4242 DEPLOY_TAG="${TAG}" \
    WEB_SAAS_ACCEPTANCE_TIMEOUT_SECONDS=0 WEB_SAAS_ACCEPTANCE_POLL_SECONDS=0 \
    "$@" bash "${script}" "${mode}" 2>&1)" || rc=$?
}
expect() { # <name> <condition...>
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); printf '  [PASS] %s\n' "${name}"; else
    printf '  [FAIL] %s (rc=%s)\n%s\n' "${name}" "${rc}" "$(sed 's/^/         /' <<<"${out}")"; exit 1; fi
}
rc_is() { [[ "${rc}" == "$1" ]]; }
has() { grep -Fq -- "$1" <<<"${out}"; }

echo "=== Web SaaS upgrade acceptance: verify rules ==="

run verify PROBE="$(probe "${TAG}" 200 307)"
expect "healthy services on the deployed tag pass" rc_is 0
expect "the remote side runs through sudo for a non-root CMDB user" \
  grep -Fq "sudo -n bash -s -- compare 4242" "${workdir}/ssh.log"

run verify PROBE="$(probe uat-daily-build-2026.10.03-r1 200 200)"
expect "an image still on the previous tag fails" rc_is 1
expect "the stale image is named with the expected tag" \
  has "web-saas-accounts runs ghcr.io/ai-workspace-services/accounts:uat-daily-build-2026.10.03-r1, expected tag ${TAG}"

run verify PROBE="$(probe "${TAG}" 503 200)"
expect "Accounts readyz 503 fails" has "Accounts readyz answered 503"

run verify PROBE="$(probe "${TAG}" 200 500)"
expect "Console 500 fails" has "Console / answered 500"

run verify PROBE="$(probe "${TAG}" 200 none)"
expect "an unreachable Console fails" has "Console / answered none"

run verify PROBE="$(probe "${TAG}" 200 200 missing)"
expect "a missing Console container fails" has "web-saas-console container is missing"

run verify PROBE="bash: line 1: docker: command not found"
expect "a probe that returns nothing is a failure, not a pass" \
  bash -c '[ "$0" = 1 ] && grep -Fq "probe returned no '"'"'http accounts_readyz'"'"' result" <<<"$1"' "${rc}" "${out}"

run verify PROBE="$(probe some-other-tag 200 200)" DEPLOY_TAG=
expect "without a DEPLOY_TAG the running tag is recorded, not enforced" rc_is 0

run verify PROBE="$(probe "${TAG}" 200 200)" PROBE_1="$(probe old 503 none)" \
  WEB_SAAS_ACCEPTANCE_TIMEOUT_SECONDS=30
expect "a stack that converges within the window passes" rc_is 0
expect "convergence took more than one probe" \
  test "$(cat "${workdir}/ssh.log.probe")" = 2

run verify PROBE="$(probe "${TAG}" 200 200)" SSH_DOWN=1
expect "an unreachable host fails before any probe" \
  bash -c '[ "$0" = 1 ] && grep -Fq "Cannot open an authenticated SSH session" <<<"$1"' "${rc}" "${out}"

run baseline SSH_DOWN=1
expect "baseline refuses to proceed when the host cannot be read" \
  bash -c '[ "$0" = 1 ]' "${rc}"

run baseline BASELINE_FAILS=2 WEB_SAAS_BASELINE_RETRY_SECONDS=0
expect "a transient capture failure is retried" \
  bash -c '[ "$0" = 0 ] && grep -Fq "baseline=captured" <<<"$1"' "${rc}" "${out}"

run baseline BASELINE_FAILS=3 WEB_SAAS_BASELINE_RETRY_SECONDS=0
expect "a persistent capture failure blocks the tag update" \
  bash -c '[ "$0" = 1 ] && grep -Fq "refusing to move GitOps tags" <<<"$1"' "${rc}" "${out}"

run baseline
expect "baseline prints the host summary" bash -c '[ "$0" = 0 ] && grep -Fq "baseline=captured" <<<"$1"' "${rc}" "${out}"

run bogus
expect "an unknown mode is a usage error" rc_is 2

echo "=== Orchestrator wiring ==="
python3 - "${workflow}" <<'PY'
import sys
from pathlib import Path

import yaml

jobs = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))["jobs"]
script = ".github/scripts/platform-ops/observe/platform-ops_web-saas-upgrade-acceptance.sh"

baseline = jobs["capture_web_saas_baseline"]
assert baseline["needs"] == ["provision"], "baseline must not wait on anything that moves tags"
assert "deployment_env != 'prod'" in baseline["if"], "baseline stays out of PROD until decided"
assert any(f"{script} baseline" in s.get("run", "") for s in baseline["steps"])

tags = jobs["update_gitops_tags"]
assert "capture_web_saas_baseline" in tags["needs"], "tags must not move before the baseline"
assert "needs.capture_web_saas_baseline.result == 'success' || needs.capture_web_saas_baseline.result == 'skipped'" in tags["if"]

accept = jobs["accept_web_saas_upgrade"]
needs = set(accept["needs"])
assert {"deploy_web_saas", "initialize_web_saas_databases", "capture_web_saas_baseline"} <= needs
assert "switch_dns" not in needs and "switch_dns" not in accept["if"], "acceptance must not depend on DNS"
assert "dns_mode" not in accept["if"], "acceptance must run for dns_mode=none"
verify = [s for s in accept["steps"] if f"{script} verify" in s.get("run", "")]
assert verify and verify[0]["env"]["DEPLOY_TAG"] == "${{ needs.provision.outputs.deploy_tag }}"

summary = jobs["deployment_summary"]
assert "accept_web_saas_upgrade" in summary["needs"] and "capture_web_saas_baseline" in summary["needs"]
print("  [PASS] baseline precedes tag updates; acceptance runs without DNS; summary reports both")
PY
pass=$((pass + 1))

echo "web_saas_upgrade_acceptance_test: ${pass} checks passed"
