#!/usr/bin/env bash
set -euo pipefail

# Hybrid is not a third deployment target: it is the serverless edge chain with
# a different backend policy on the three edge-gateway Workers. This script is
# the gate that keeps that true. It fails if the hybrid declaration has drifted
# away from its serverless sibling in any respect other than backend policy.

HYBRID_CONFIG="${HYBRID_CONFIG:?HYBRID_CONFIG must point to the rendered hybrid manifest}"
SERVERLESS_CONFIG="${SERVERLESS_CONFIG:?SERVERLESS_CONFIG must point to the rendered serverless manifest}"

command -v jq >/dev/null 2>&1 || { echo "jq is required to verify the hybrid contract" >&2; exit 1; }
for f in "${HYBRID_CONFIG}" "${SERVERLESS_CONFIG}"; do
  test -f "${f}" || { echo "Routing manifest not found: ${f}" >&2; exit 1; }
done

fail() { echo "Hybrid contract violation: $*" >&2; exit 1; }

hybrid_mode="$(jq -r '.spec.runtime.mode // empty' "${HYBRID_CONFIG}")"
serverless_mode="$(jq -r '.spec.runtime.mode // empty' "${SERVERLESS_CONFIG}")"
test "${hybrid_mode}" = hybrid || fail "expected hybrid manifest runtime.mode=hybrid, got ${hybrid_mode:-<empty>}"
test "${serverless_mode}" = serverless || fail "expected serverless manifest runtime.mode=serverless, got ${serverless_mode:-<empty>}"

# 1. The frontend and the Cloudflare resource inventory must be shared, not
#    duplicated. A mode flip may never redeploy or rename a frontend boundary.
shared_filter='{
  pages: .spec.cloudflare,
  frontend_router: .spec.serverless.frontend_router,
  ssr: .spec.serverless.ssr,
  cloud_run: .spec.serverless.cloud_run,
  console_host: .spec.serverless.console_host,
  accounts_host: .spec.serverless.accounts_host,
  billing_host: .spec.serverless.billing_host,
  gateway_boundaries: [.spec.serverless.edge_gateway.boundaries[] | {id, worker_name, routes}]
}'
if ! diff -u \
  <(jq -S "${shared_filter}" "${SERVERLESS_CONFIG}") \
  <(jq -S "${shared_filter}" "${HYBRID_CONFIG}"); then
  fail "hybrid must reuse the serverless edge inventory unchanged (see diff above)"
fi

# 2. Failover crosses a database boundary, so only safe methods may cross it.
mapfile -t failover_methods < <(jq -r '.spec.serverless.edge_gateway.defaults.failover_methods // [] | .[]' "${HYBRID_CONFIG}")
test "${#failover_methods[@]}" -gt 0 || fail "hybrid must declare edge_gateway.defaults.failover_methods"
for method in "${failover_methods[@]}"; do
  case "${method}" in
    GET|HEAD|OPTIONS) ;;
    *) fail "failover_methods may only contain safe methods; got ${method}" ;;
  esac
done

# 3. The split itself: selfhost primary, Cloud Run fallback, and the fallback
#    must be the Cloud Run service this same manifest declares.
primary="$(jq -r '.spec.serverless.edge_gateway.defaults.primary_upstream // empty' "${HYBRID_CONFIG}")"
fallback="$(jq -r '.spec.serverless.edge_gateway.defaults.fallback_upstream // empty' "${HYBRID_CONFIG}")"
cloud_run_accounts="$(jq -r '.spec.serverless.cloud_run.accounts // empty' "${HYBRID_CONFIG}")"
lb_primary="$(jq -r '.spec.runtime.routing["load-balancer"].hybrid.primary // empty' "${HYBRID_CONFIG}")"
lb_fallback="$(jq -r '.spec.runtime.routing["load-balancer"].hybrid.fallback // empty' "${HYBRID_CONFIG}")"
test "${lb_primary}" = selfhost || fail "load-balancer.hybrid.primary must be selfhost, got ${lb_primary:-<empty>}"
test "${lb_fallback}" = serverless || fail "load-balancer.hybrid.fallback must be serverless, got ${lb_fallback:-<empty>}"
[[ "${primary}" == *"-selfhost-"* ]] || fail "primary_upstream must be a selfhost origin, got ${primary:-<empty>}"
test "${fallback}" = "${cloud_run_accounts}" || fail "fallback_upstream (${fallback:-<empty>}) must equal cloud_run.accounts (${cloud_run_accounts:-<empty>})"

# 4. Selfhost is the single writer: mutating traffic never leaves the primary.
data_primary="$(jq -r '.spec.runtime.data.primary // empty' "${HYBRID_CONFIG}")"
test "${data_primary}" = selfhost || fail "hybrid runtime.data.primary must be selfhost, got ${data_primary:-<empty>}"

echo "Hybrid contract verified:"
echo "  primary        : ${primary}"
echo "  fallback       : ${fallback}"
echo "  failover       : ${failover_methods[*]} (safe methods only)"
echo "  single writer  : selfhost / self-managed-postgresql"
echo "  frontend       : reused unchanged from the serverless declaration"

{
  echo "## Hybrid routing contract"
  echo
  echo "| Property | Value |"
  echo "| --- | --- |"
  echo "| Primary upstream | \`${primary}\` |"
  echo "| Fallback upstream | \`${fallback}\` |"
  echo "| Failover methods | ${failover_methods[*]} |"
  echo "| Single writer | selfhost / self-managed-postgresql |"
  echo "| Frontend | reused from serverless (not redeployed) |"
  echo "| Edge gateway stage | ${EDGE_GATEWAY_RESULT:-not run} |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
