#!/usr/bin/env bash
set -euo pipefail

# This check protects the Toolkit's release routing contract. It intentionally
# validates only tag/ref policy and the local snapshot-tag routing test; runtime
# deployment, database, and product checks belong to their owning repositories.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
route_policy="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_route-ref-to-an-explicit-profile.sh"
snapshot_routing_test="${repo_root}/scripts/tests/control_plane/daily_snapshot_tag_routing_test.sh"

[[ -f "${route_policy}" ]] || {
  echo "missing release route policy: ${route_policy}" >&2
  exit 1
}
[[ -x "${snapshot_routing_test}" ]] || {
  echo "snapshot tag routing test must be executable: ${snapshot_routing_test}" >&2
  exit 1
}

# Keep the policy assertions close to the routing implementation so a release
# PR cannot silently broaden production tag/ref acceptance.
grep -Fq 'prod:v*)' "${route_policy}" || {
  echo "production must accept only v* deployment tags" >&2
  exit 1
}
grep -Fq 'uat:v*|sit:v*)' "${route_policy}" || {
  echo "sit/uat tag policy is missing" >&2
  exit 1
}
grep -Fq 'refs/tags/v*|refs/heads/release/v*' "${route_policy}" || {
  echo "production ref policy is missing" >&2
  exit 1
}
grep -Fq '"|latest|main)' "${route_policy}" || {
  echo "mutable deployment tag guard is missing" >&2
  exit 1
}

bash "${snapshot_routing_test}"
echo "release TAG rules passed"
