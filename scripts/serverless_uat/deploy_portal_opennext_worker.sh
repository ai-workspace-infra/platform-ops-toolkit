#!/usr/bin/env bash
set -euo pipefail

# Deploy the portal Server Runtime to the UAT OpenNext/Cloudflare Worker target.
PORTAL_DIR="${PORTAL_DIR:?PORTAL_DIR must point to a checked-out portal repository}"
CLOUDFLARE_ENV="${CLOUDFLARE_ENV:-uat}"

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are required" >&2
  exit 1
fi

test -f "${PORTAL_DIR}/package.json"
pushd "${PORTAL_DIR}" > /dev/null
corepack enable
yarn install --immutable
yarn build:frontend-server:worker
yarn exec opennextjs-cloudflare deploy --config wrangler.worker.jsonc --env "${CLOUDFLARE_ENV}"
popd > /dev/null
