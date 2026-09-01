#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:?CLOUDFLARE_BOUNDARY_CONFIG is required}"
# Cloudflare may finish the Worker deployment before the Pages asset hostname
# and edge cache are ready. Keep the default window long enough for that
# propagation, while retaining VERIFY_ATTEMPTS/VERIFY_INTERVAL_SECONDS as
# explicit workflow overrides for faster or slower environments.
VERIFY_ATTEMPTS="${VERIFY_ATTEMPTS:-30}"
VERIFY_INTERVAL_SECONDS="${VERIFY_INTERVAL_SECONDS:-10}"

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 1; }

console_host="$(jq -er '.spec.serverless.console_host' "${CONFIG_FILE}")"
static_cdn_url="$(jq -r '.spec.cloudflare.static_cdn_url // empty' "${CONFIG_FILE}")"
static_cdn_origin="${static_cdn_url:-https://${console_host}}"
probe_root="$(mktemp -d)"
trap 'rc=$?; rm -rf "${probe_root}"; exit ${rc}' EXIT

header_value() {
  local header_file="$1"
  local name="$2"
  awk -v header_name="${name}" 'BEGIN { IGNORECASE=1 }
    $0 ~ "^" header_name ":" {
      sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0
    }
    END { print value }
  ' "${header_file}"
}

for ((attempt = 1; attempt <= VERIFY_ATTEMPTS; attempt++)); do
  probe_id="$(date +%s)-${attempt}"
  public_headers="${probe_root}/public.headers"
  public_body="${probe_root}/public.html"
  console_headers="${probe_root}/console.headers"
  console_body="${probe_root}/console.html"

  public_status="$(curl --silent --show-error --compressed --dump-header "${public_headers}" --output "${public_body}" --write-out '%{http_code}' --max-time 30 "https://${console_host}/?__boundary_probe=${probe_id}" || true)"
  console_status="$(curl --silent --show-error --compressed --dump-header "${console_headers}" --output "${console_body}" --write-out '%{http_code}' --max-time 30 "https://${console_host}/dashboard/__boundary_probe__?id=${probe_id}" || true)"
  public_route="$(header_value "${public_headers}" 'X-Frontend-Route')"
  console_route="$(header_value "${console_headers}" 'X-Frontend-Route')"
  public_css="$(grep -oE '/_edge/public/_next/static/[^"? ]+\.css' "${public_body}" | head -1 || true)"
  console_css="$(grep -oE '/_edge/console/_next/static/[^"? ]+\.css' "${console_body}" | head -1 || true)"

  if [[ "${public_status}" == "200" && "${console_status}" =~ ^(200|404)$ &&
        "${public_route}" == "ssr-public" && "${console_route}" == "ssr-console" &&
        -n "${public_css}" && -n "${console_css}" ]]; then
    public_css_headers="${probe_root}/public-css.headers"
    public_css_body="${probe_root}/public.css"
    console_css_headers="${probe_root}/console-css.headers"
    console_css_body="${probe_root}/console.css"
    public_css_status="$(curl --silent --show-error --compressed --dump-header "${public_css_headers}" --output "${public_css_body}" --write-out '%{http_code}' --max-time 30 "${static_cdn_origin}${public_css}" || true)"
    console_css_status="$(curl --silent --show-error --compressed --dump-header "${console_css_headers}" --output "${console_css_body}" --write-out '%{http_code}' --max-time 30 "${static_cdn_origin}${console_css}" || true)"
    public_css_route="$(header_value "${public_css_headers}" 'X-Frontend-Route')"
    console_css_route="$(header_value "${console_css_headers}" 'X-Frontend-Route')"

    if [[ "${public_css_status}" == "200" && "${console_css_status}" == "200" &&
          "${public_css_route}" == "ssr-public" && "${console_css_route}" == "ssr-console" ]] &&
       grep -Fq '.text-4xl' "${public_css_body}"; then
      public_hash="$(sha256sum "${public_css_body}" | awk '{print $1}')"
      console_hash="$(sha256sum "${console_css_body}" | awk '{print $1}')"
      echo "Frontend boundary assets verified: host=${console_host}, public_route=${public_route}, console_route=${console_route}, public_css=${public_css}, public_sha256=${public_hash}, console_css=${console_css}, console_sha256=${console_hash}"
      exit 0
    fi
  fi

  echo "Waiting for frontend boundary assets (${attempt}/${VERIFY_ATTEMPTS}): public_http=${public_status}, public_route=${public_route:-missing}, public_css=${public_css:-missing}, console_http=${console_status}, console_route=${console_route:-missing}, console_css=${console_css:-missing}" >&2
  if (( attempt < VERIFY_ATTEMPTS )); then
    sleep "${VERIFY_INTERVAL_SECONDS}"
  fi
done

echo "Frontend boundary asset verification failed for ${console_host}." >&2
exit 1
