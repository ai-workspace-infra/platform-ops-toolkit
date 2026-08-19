#!/usr/bin/env bash
set -euo pipefail

# The SSR boundaries build their client chunks against
# <static_cdn_url>/_edge/<boundary>, so the Cloudflare Pages deployment that
# backs the CDN must carry those assets.  Guard both halves of the hand-off:
# the workflow wiring and the deploy script that refuses to publish a Pages
# site which would 404 every SSR chunk.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/serverless-orchestrator.yml"

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys

import yaml

jobs = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))["jobs"]

ssr_steps = jobs["cloudflare_ssr"]["steps"]
deploy_step = next(s for s in ssr_steps if s.get("name") == "Deploy SSR Worker boundary")
if "EDGE_ASSETS_OUT" not in deploy_step["env"]:
    raise SystemExit("the SSR boundary deploy must collect its edge assets via EDGE_ASSETS_OUT")

upload_step = next((s for s in ssr_steps if str(s.get("uses", "")).startswith("actions/upload-artifact")), None)
if upload_step is None:
    raise SystemExit("the SSR boundary job must upload its edge assets for the static-pages job")
if upload_step["with"].get("if-no-files-found") != "error":
    raise SystemExit("a boundary that produced no edge assets must fail the job, not upload nothing")
if upload_step["with"].get("name") != "edge-assets-${{ matrix.boundary }}":
    raise SystemExit("edge asset artifacts must be named per boundary")

pages_steps = jobs["static_pages"]["steps"]
download_step = next((s for s in pages_steps if str(s.get("uses", "")).startswith("actions/download-artifact")), None)
if download_step is None:
    raise SystemExit("the static-pages job must download the boundary edge assets")
if download_step["with"].get("pattern") != "edge-assets-*" or download_step["with"].get("merge-multiple") is not True:
    raise SystemExit("the static-pages job must merge every boundary artifact into one directory")

pages_deploy = next(s for s in pages_steps if s.get("name") == "Deploy Cloudflare Pages static assets")
if "EDGE_ASSETS_DIR" not in pages_deploy["env"]:
    raise SystemExit("the Pages deploy must receive the collected edge assets via EDGE_ASSETS_DIR")
PY

# The deploy script must refuse to publish when a static CDN is declared but no
# boundary assets were handed over.
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/bin" "${workdir}/portal"
printf '{}\n' > "${workdir}/portal/package.json"
for stub in yarn corepack; do
  cat > "${workdir}/bin/${stub}" <<'STUB'
#!/usr/bin/env bash
echo "stub: $(basename "$0") $* console_origin=${NEXT_PUBLIC_CONSOLE_ORIGIN:-<unset>} cdn=${NEXT_PUBLIC_STATIC_CDN_URL:-<unset>}" >> "${STUB_LOG}"
exit 0
STUB
  chmod +x "${workdir}/bin/${stub}"
done

cat > "${workdir}/edge-routing.json" <<'JSON'
{
  "kind": "EdgeRoutingConfig",
  "spec": {
    "cloudflare": {
      "pages_project": "ai-workspace-portal-uat",
      "pages_branch": "uat",
      "static_cdn_url": "https://ai-workspace-portal-uat.pages.dev"
    },
    "serverless": {
      "console_host": "console-serverless-uat.onwalk.net",
      "ssr": [{ "id": "public" }, { "id": "auth" }]
    }
  }
}
JSON

run_deploy() {
  env PATH="${workdir}/bin:${PATH}" \
    STUB_LOG="${workdir}/stub.log" \
    PORTAL_DIR="${workdir}/portal" \
    CLOUDFLARE_ENV=uat \
    CLOUDFLARE_API_TOKEN=stub \
    CLOUDFLARE_ACCOUNT_ID=stub \
    CLOUDFLARE_BOUNDARY_CONFIG="${workdir}/edge-routing.json" \
    "$@" \
    bash "${repo_root}/scripts/serverless_uat/deploy_cloudflare_pages.sh"
}

if run_deploy > "${workdir}/missing.log" 2>&1; then
  echo "expected the Pages deploy to fail when boundary assets are missing" >&2
  exit 1
fi
grep -Fq "refusing to publish a Pages deployment that 404s every SSR chunk" "${workdir}/missing.log"

# A partially collected set is just as broken as an empty one.
mkdir -p "${workdir}/edge-assets/_edge/public/_next/static"
printf 'chunk\n' > "${workdir}/edge-assets/_edge/public/_next/static/app.js"
if run_deploy EDGE_ASSETS_DIR="${workdir}/edge-assets" > "${workdir}/partial.log" 2>&1; then
  echo "expected the Pages deploy to fail when a boundary is missing from the collected assets" >&2
  exit 1
fi
grep -Fq "Missing edge assets for SSR boundary 'auth'" "${workdir}/partial.log"

# With every boundary present the assets land in the deployed payload.
mkdir -p "${workdir}/edge-assets/_edge/auth/_next/static"
printf 'chunk\n' > "${workdir}/edge-assets/_edge/auth/_next/static/app.js"
run_deploy EDGE_ASSETS_DIR="${workdir}/edge-assets" > "${workdir}/merged.log" 2>&1
test -f "${workdir}/portal/static-dashboard/out/_edge/public/_next/static/app.js"
test -f "${workdir}/portal/static-dashboard/out/_edge/auth/_next/static/app.js"
grep -Fq "wrangler pages deploy static-dashboard/out" "${workdir}/stub.log"
# The exported 404 page can only hand a visitor back to the console when the
# build knows the console origin.
grep -Fq "build:static-dashboard console_origin=https://console-serverless-uat.onwalk.net" "${workdir}/stub.log"

# The Pages hostname only holds the static export, so SSR entry points such as
# /login must hand the visitor back to the console host instead of rendering the
# static 404 page.
redirects="${workdir}/portal/static-dashboard/out/_redirects"
grep -Fqx "/login https://console-serverless-uat.onwalk.net/login 302" "${redirects}"
grep -Fqx "/login/* https://console-serverless-uat.onwalk.net/login/:splat 302" "${redirects}"
grep -Fqx "/panel https://console-serverless-uat.onwalk.net/panel 302" "${redirects}"
# Redirects are evaluated before assets on Cloudflare Pages, so a rule must
# never cover the boundary assets the same deployment publishes.
if grep -Eq '^/(\*|_edge|_next)' "${redirects}"; then
  echo "the Pages redirects must not shadow the static assets served from the same deployment" >&2
  exit 1
fi

echo "serverless_pages_edge_assets_contract_test: PASS"
