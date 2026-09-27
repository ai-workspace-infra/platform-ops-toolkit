#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_IP:?TARGET_IP is required}"
: "${SSH_PRIVATE_KEY_PATH:?SSH_PRIVATE_KEY_PATH is required}"
: "${DASHBOARD_SOURCE:?DASHBOARD_SOURCE is required}"
: "${DNS_ACTION:=none}"
[[ "${TARGET_IP}" =~ ^[0-9.]+$ ]] || { echo "Target must be an IPv4 address." >&2; exit 2; }
[[ -d "${DASHBOARD_SOURCE}" ]] || { echo "Dashboard source directory is missing." >&2; exit 1; }

shopt -s nullglob
expected=("${DASHBOARD_SOURCE}"/*.json)
((${#expected[@]} > 0)) || { echo "No Git-managed dashboard JSON files found." >&2; exit 1; }
expected_manifest="$(cd "${DASHBOARD_SOURCE}" && for file in *.json; do sha256sum "${file}"; done | sort)"
ssh_args=(-i "${SSH_PRIVATE_KEY_PATH}" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)

echo "Checking the target Grafana API and service containers."
ssh "${ssh_args[@]}" "root@${TARGET_IP}" bash -s <<'REMOTE'
set -euo pipefail
python3 - <<'PY'
import json, time, urllib.request
checks = {
    'VictoriaMetrics': ('http://127.0.0.1:9090/metrics', False),
    'VictoriaLogs': ('http://127.0.0.1:9428/metrics', False),
    'VictoriaTraces': ('http://127.0.0.1:10428/metrics', False),
    'Grafana': ('http://127.0.0.1:3030/api/health', True),
}
for name, (url, is_grafana) in checks.items():
    for _ in range(24):
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                payload = json.load(response) if is_grafana else None
            if not is_grafana or payload.get('database') == 'ok':
                break
        except Exception:
            pass
        time.sleep(5)
    else:
        raise SystemExit(f'{name} health endpoint did not become ready: {url}')
PY
for container in xstream_victoriametrics xstream_victorialogs xstream_victoriatraces xstream_grafana; do
  test "$(docker inspect --format '{{.State.Running}}' "${container}")" = true
done
cd /opt/observability-server/grafana/dashboards
for file in *.json; do test -f "${file}"; done
for file in *.json; do sha256sum "${file}"; done | sort
REMOTE

actual_manifest="$(ssh "${ssh_args[@]}" "root@${TARGET_IP}" 'cd /opt/observability-server/grafana/dashboards && for file in *.json; do sha256sum "${file}"; done | sort')"
if [[ "${actual_manifest}" != "${expected_manifest}" ]]; then
  echo "The target dashboard JSON set differs from the Git source." >&2
  diff -u <(printf '%s\n' "${expected_manifest}") <(printf '%s\n' "${actual_manifest}") || true
  exit 1
fi

if [[ "${DNS_ACTION}" == cutover ]]; then
  echo "Target Grafana, four service containers, and ${#expected[@]} Git-managed dashboard JSON files are ready for DNS cutover; HTTPS will be checked after certificate issuance."
else
  http_code="$(curl --connect-timeout 8 --max-time 20 -k --silent --show-error --output /dev/null \
    --write-out '%{http_code}' --resolve "observability.svc.plus:443:${TARGET_IP}" \
    https://observability.svc.plus/grafana/)"
  [[ "${http_code}" == 200 || "${http_code}" == 302 ]] || { echo "Target HTTPS returned HTTP ${http_code}." >&2; exit 1; }
  echo "Target Grafana, four service containers, ${#expected[@]} dashboard JSON files, and HTTPS host routing are healthy."
fi
