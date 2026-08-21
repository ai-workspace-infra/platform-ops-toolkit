#!/usr/bin/env bash
set -euo pipefail

: "${MATRIX_HOST:?MATRIX_HOST is required}"
: "${ANSIBLE_INVENTORY:?ANSIBLE_INVENTORY is required}"
: "${VECTOR_BILLING_INGEST_URL:?VECTOR_BILLING_INGEST_URL is required}"

case "${VECTOR_BILLING_INGEST_URL}" in
  https://billing-*-*/v1/ingest/snapshots) ;;
  *)
    echo "::error::VECTOR_BILLING_INGEST_URL must be an HTTPS Billing ingest endpoint: ${VECTOR_BILLING_INGEST_URL}" >&2
    exit 1
    ;;
esac

remote_script=$(cat <<'REMOTE'
set -eu

# The monitor job runs on every host. Only an Agent Proxy owns the Xray
# services; other hosts are intentionally skipped.
if ! systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'xray.service'; then
  echo "xray-billing-chain: SKIP (host does not own xray.service)"
  exit 0
fi

for unit in xray.service xray-tcp.service xray-exporter-xhttp.service xray-exporter-tcp.service vector.service; do
  systemctl is-active --quiet "${unit}" || {
    echo "xray-billing-chain: ${unit} is not active" >&2
    exit 1
  }
done

test -s /etc/vector/vector.toml
grep -Fq 'VECTOR_SNAPSHOT_URL=http://127.0.0.1:8686' /etc/xray-exporter.env
grep -Fq '[sources.xray_snapshot_input]' /etc/vector/vector.toml
grep -Fq '[sinks.billing_snapshot_ingest]' /etc/vector/vector.toml
grep -Fq "__BILLING_INGEST_URL__" /etc/vector/vector.toml

for endpoint in http://127.0.0.1:8080/scrape http://127.0.0.1:8081/scrape; do
  code=$(curl --silent --show-error --max-time 10 -o /dev/null -w '%{http_code}' "${endpoint}")
  test "${code}" = 200 || {
    echo "xray-billing-chain: ${endpoint} returned HTTP ${code}" >&2
    exit 1
  }
done

vector_code=$(curl --silent --show-error --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:8686/)
case "${vector_code}" in
  2??|3??|4??) ;;
  *)
    echo "xray-billing-chain: Vector snapshot listener is unavailable (HTTP ${vector_code})" >&2
    exit 1
    ;;
esac

billing_body=$(mktemp)
trap 'rm -f "${billing_body}"' EXIT
billing_code=$(curl --silent --show-error --max-time 15 -X POST \
  -H 'Content-Type: application/json' --data '{}' -o "${billing_body}" -w '%{http_code}' \
  "__BILLING_INGEST_URL__")
billing_size=$(wc -c <"${billing_body}")
case "${billing_code}" in
  404|000)
    echo "xray-billing-chain: Billing ingest endpoint is unavailable (HTTP ${billing_code})" >&2
    exit 1
    ;;
  *)
    if [[ "${billing_size}" -eq 0 ]]; then
      echo "xray-billing-chain: Billing ingest endpoint returned an empty response (HTTP ${billing_code}); this usually indicates an unmatched proxy route" >&2
      exit 1
    fi
    echo "xray-billing-chain: OK (Xray -> exporter -> Vector -> Billing endpoint HTTP ${billing_code}, ${billing_size} bytes)"
    ;;
esac
REMOTE
)

remote_script=${remote_script//__BILLING_INGEST_URL__/${VECTOR_BILLING_INGEST_URL}}

ansible "${MATRIX_HOST}" \
  -i "${ANSIBLE_INVENTORY}" \
  --become \
  -m ansible.builtin.shell \
  -a "${remote_script}" \
  -o
