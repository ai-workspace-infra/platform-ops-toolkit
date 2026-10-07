#!/usr/bin/env bash
set -euo pipefail
action="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/runtime"
export RUNNER_TEMP="$tmp/runtime" GITHUB_ENV="$tmp/environment" VAULT_ADDR=https://vault.svc.plus VAULT_TOKEN=fixture-token
export RUNTIME_ENVIRONMENT=uat CLOUD_RUN_SERVICE=billing-service MOCK_ROOT="$tmp" PATH="$tmp/bin:$PATH"
export CLOUDFLARE_BOUNDARY_CONFIG="$tmp/routing" GITOPS_OAUTH_GITHUB_CONFIG="$tmp/oauth"
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output= url=
while (( $# )); do
  case "$1" in -o) output="$2"; shift 2 ;; -H|--max-time|-w) shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac
done
case "$url" in
  */supabase) source=database ;;
  */WEB_SAAS) source=runtime-data ;;
  */CICD) source=cicd ;;
  */oauth/github) source=oauth-secret ;;
  *) echo 404; echo '{}' > "$output"; exit 0 ;;
esac
echo "$source" >> "$MOCK_ROOT/reads"
cp "$MOCK_ROOT/$source" "$output"
printf 200
MOCK
chmod 755 "$tmp/bin/curl"
fixture() {
  rm -f "$GITHUB_ENV" "$tmp/reads"
  jq -n '{data:{data:{PROJECT_REF:"tenant",SUPABASE_CONNECT_URI:"postgresql://postgres:old@aws.pooler.supabase.com:5432/postgres",DATABASE_PASSWORD:"a@b:/#?"}}}' > "$tmp/database"
  jq -n '{data:{data:{INTERNAL_SERVICE_TOKEN:"fixture-internal",KNOWLEDGE_REPO_PATH:"/knowledge",AUTH_TOKEN_PUBLIC_TOKEN:"fixture-public",AUTH_TOKEN_REFRESH_SECRET:"fixture-refresh",AUTH_TOKEN_ACCESS_SECRET:"fixture-access"}}}' > "$tmp/runtime-data"
  jq -n '{data:{data:{ROOT_BOOTSTRAP_PASSWORD:"fixture-root"}}}' > "$tmp/cicd"
  jq -n '{data:{data:{client_secret:"fixture-oauth"}}}' > "$tmp/oauth-secret"
  jq -n '{kind:"EdgeRoutingConfig",metadata:{environment:"uat"},spec:{serverless:{console_host:"console-uat.example.org"}}}' > "$tmp/routing"
  jq -n '{enabled:true,client_id:"fixture-id",frontend_url:"https://console-uat.example.org",redirect_url:"https://accounts-uat.example.org/oauth/github/callback",vault_secret_path:"kv/data/uat/accounts/oauth/github"}' > "$tmp/oauth"
  export CLOUD_RUN_SERVICE=billing-service
}
run() { bash "$action/prepare.sh" > "$tmp/log" 2>&1 || { sed -n '/jq: error/p' "$tmp/log" >&2; return 1; }; }
reject() { if run; then echo "Unexpected acceptance: $1" >&2; exit 1; fi; [[ ! -s "$GITHUB_ENV" ]]; echo "PASS reject $1"; }
fixture; run; grep -Eq 'postgresql://postgres.tenant:a%40b%3A%2F%23%3F@' "$GITHUB_ENV"; ! grep -Eq 'cicd' "$tmp/reads"; echo 'PASS encoded database credential and minimal service reads'
fixture; jq '.data.data.DATABASE_PASSWORD = "" | .data.data.SUPABASE_CONNECT_URI="postgresql://postgres:p%40ss@aws.pooler.supabase.com:5432/postgres"' "$tmp/database" > "$tmp/new"; mv "$tmp/new" "$tmp/database"; run; grep -Eq 'postgres.tenant:p%40ss@' "$GITHUB_ENV"; echo 'PASS encoded URI credential retained'
fixture; jq '.data.data.DATABASE_PASSWORD = "" | .data.data.SUPABASE_CONNECT_URI="postgresql://postgres@aws.pooler.supabase.com:5432/postgres"' "$tmp/database" > "$tmp/new"; mv "$tmp/new" "$tmp/database"; reject 'missing database password'
fixture; jq '.metadata.environment="prod"' "$tmp/routing" > "$tmp/new"; mv "$tmp/new" "$tmp/routing"; reject 'different environment declaration'
fixture; CLOUD_RUN_SERVICE=accounts run; grep -Eq 'GITHUB_CLIENT_SECRET' "$GITHUB_ENV"; echo 'PASS Accounts runtime contract'
fixture; jq '.data.data={}' "$tmp/cicd" > "$tmp/new"; mv "$tmp/new" "$tmp/cicd"; CLOUD_RUN_SERVICE=accounts reject 'missing bootstrap credential'
echo '6 private runtime checks passed using mock Vault responses.'
