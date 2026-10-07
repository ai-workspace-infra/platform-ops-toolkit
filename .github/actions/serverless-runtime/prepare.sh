#!/usr/bin/env bash
set -euo pipefail
umask 077
case "${RUNTIME_ENVIRONMENT:-}" in sit|uat|prod) ;; *) exit 2 ;; esac
case "${CLOUD_RUN_SERVICE:-}" in accounts|billing-service|content-service) ;; *) exit 2 ;; esac
: "${VAULT_ADDR:?}" "${VAULT_TOKEN:?}" "${GITHUB_ENV:?}" "${RUNNER_TEMP:?}" "${CLOUDFLARE_BOUNDARY_CONFIG:?}"
[[ "$VAULT_ADDR" == https://vault.svc.plus ]] || exit 2
temporary="$(mktemp -d "$RUNNER_TEMP/serverless-inputs.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
trap 'echo "::error::Cloud Run runtime contract is incomplete; private response withheld." >&2' ERR
printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" > "$temporary/headers"
read_vault() {
  local path="$1" file="$2" optional="${3:-false}" status
  status="$(curl --silent --show-error --max-time 20 -H "@$temporary/headers" \
    -o "$temporary/response" -w '%{http_code}' "$VAULT_ADDR/v1/$path" 2>/dev/null)"
  if [[ "$status" == 404 && "$optional" == true ]]; then printf '{}\n' > "$file"; return; fi
  [[ "$status" == 200 ]] || return 1
  jq -e '.data.data | select(type == "object")' "$temporary/response" > "$file"
}
read_vault "kv/data/$RUNTIME_ENVIRONMENT/serverless/supabase" "$temporary/database.json"
# LEGACY read-only compatibility: these two shared Vault records remain until
# an independently verified environment-first credential cutover is available.
read_vault kv/data/WEB_SAAS "$temporary/runtime.json"
printf '{}\n' > "$temporary/cicd.json"
printf '{}\n' > "$temporary/billing.json"
printf '{}\n' > "$temporary/zero.json"
printf '{}\n' > "$temporary/oauth.json"
if [[ "$CLOUD_RUN_SERVICE" == accounts ]]; then
  read_vault kv/data/CICD "$temporary/cicd.json"
  read_vault "kv/data/$RUNTIME_ENVIRONMENT/billing-service" "$temporary/billing.json" true
  read_vault "kv/data/$RUNTIME_ENVIRONMENT/xconnect-one" "$temporary/zero.json" true
  : "${GITOPS_OAUTH_GITHUB_CONFIG:?}"
  jq -e --arg path "kv/data/$RUNTIME_ENVIRONMENT/accounts/oauth/github" '
    .enabled == true and (.client_id | type == "string" and length > 0) and
    (.redirect_url | type == "string" and length > 0) and (.frontend_url | type == "string" and length > 0) and
    .vault_secret_path == $path and ((.vault_secret_key // "client_secret") | type == "string" and length > 0)' \
    "$GITOPS_OAUTH_GITHUB_CONFIG" >/dev/null
  read_vault "kv/data/$RUNTIME_ENVIRONMENT/accounts/oauth/github" "$temporary/oauth-secret.json"
  jq --slurpfile secret "$temporary/oauth-secret.json" '. as $metadata |
    {GITHUB_CLIENT_ID:.client_id,GITHUB_CLIENT_SECRET:$secret[0][.vault_secret_key // "client_secret"],
     OAUTH_FRONTEND_URL:.frontend_url,OAUTH_GITHUB_REDIRECT_URL:.redirect_url} |
    select(all(.[]; type == "string" and length > 0))' "$GITOPS_OAUTH_GITHUB_CONFIG" > "$temporary/oauth.json"
  [[ -s "$temporary/oauth.json" ]]
fi
jq -e --arg environment "$RUNTIME_ENVIRONMENT" '.kind == "EdgeRoutingConfig" and .metadata.environment == $environment' \
  "$CLOUDFLARE_BOUNDARY_CONFIG" >/dev/null
jq --arg environment "$RUNTIME_ENVIRONMENT" --arg service "$CLOUD_RUN_SERVICE" \
  --slurpfile db "$temporary/database.json" --slurpfile runtime "$temporary/runtime.json" \
  --slurpfile cicd "$temporary/cicd.json" --slurpfile billing "$temporary/billing.json" \
  --slurpfile zero "$temporary/zero.json" --slurpfile oauth "$temporary/oauth.json" '
  def required($value): $value | select(type == "string" and length > 0);
  . as $routing | $db[0] as $db | $runtime[0] as $runtime | $cicd[0] as $cicd |
  (if $environment == "prod" then "PROD_" else "SANDBOX_" end) as $prefix |
  ($db.SUPABASE_CONNECT_URI // $db.DATABASE_SESSION_POOLER_URL // $db.DATABASE_POOLER_URL // $db.DATABASE_DIRECT_URL | required(.)) as $raw |
  ($db.PROJECT_REF | required(.)) as $project |
  ($raw | capture("^(?<scheme>postgres(?:ql)?)://(?<userinfo>.+)@(?<host_path>[^@]+)$")) as $uri |
  (if ($db.DATABASE_PASSWORD // "") != "" then
    ($db.DATABASE_USERNAME // ($uri.userinfo | split(":")[0])) as $username |
    (if ($username | contains(".")) or ($uri.host_path | split("/")[0] | split(":")[0] | endswith(".pooler.supabase.com") | not)
     then $username else $username + "." + $project end) as $username |
    $uri.scheme + "://" + ($username | @uri) + ":" + ($db.DATABASE_PASSWORD | @uri) + "@" + $uri.host_path
   else ($uri.userinfo | capture("^(?<user>[^:]+):(?<password>.+)$")) as $userinfo |
     ($userinfo.password | required(.)) as $password |
     ($userinfo.user | if contains(".") or ($uri.host_path | split("/")[0] | split(":")[0] | endswith(".pooler.supabase.com") | not)
      then . else . + "." + $project end) as $username |
     $uri.scheme + "://" + $username + ":" + $password + "@" + $uri.host_path end) as $database_uri |
  ($routing.spec.serverless.console_host | required(.)) as $console |
  ([$console] + [($routing.spec.runtime.routing.dns.canonical_records // {}) | to_entries[] | select(.value == $console) | .key] +
    [($routing.spec.domains // {}) | to_entries[] | select(.value.serverless == $console) | .key] +
    ($routing.spec.serverless.console_aliases // []) | unique | map(select(length > 0) |
      if startswith("https://") then . else "https://" + . end) | join(",")) as $origins |
  {SUPABASE_CONNECT_URI:$database_uri,INTERNAL_SERVICE_TOKEN:($runtime.INTERNAL_SERVICE_TOKEN | required(.)),ALLOWED_ORIGINS:$origins} +
  (if $service == "accounts" then
    ($runtime.XWORKMATE_SHARED_TENANT_DOMAIN // "onwalk.net") as $domain |
    {ROOT_BOOTSTRAP_EMAIL:($cicd.ROOT_BOOTSTRAP_EMAIL // "admin@svc.plus"),
     ROOT_BOOTSTRAP_PASSWORD:($cicd.ROOT_BOOTSTRAP_PASSWORD | required(.)),
     AUTH_TOKEN_PUBLIC_TOKEN:($runtime.AUTH_TOKEN_PUBLIC_TOKEN | required(.)),
     AUTH_TOKEN_REFRESH_SECRET:($runtime.AUTH_TOKEN_REFRESH_SECRET | required(.)),
     AUTH_TOKEN_ACCESS_SECRET:($runtime.AUTH_TOKEN_ACCESS_SECRET | required(.)),
     XWORKMATE_SHARED_TENANT_DOMAIN:$domain,XWORKMATE_SHARED_TENANT_DOMAINS:($runtime.XWORKMATE_SHARED_TENANT_DOMAINS // $domain),
     XWORKMATE_BRIDGE_SERVER_URL:($runtime.XWORKMATE_BRIDGE_SERVER_URL // ("https://bridge-" + $environment + ".onwalk.net")),
     CONFIG_TEMPLATE:"/app/config/account.cloudrun.yaml",SMTP_HOST:($runtime.SMTP_HOST // "smtp.gmail.com"),
     SMTP_PORT:($runtime.SMTP_PORT // "587"),SMTP_FROM:($runtime.SMTP_FROM // "XWorkmate <no-reply@xworktech.com>"),
     STRIPE_SECRET_KEY:($billing[0][$prefix + "STRIPE_SECRET_KEY"] // $billing[0].STRIPE_SECRET_KEY // ""),
     STRIPE_WEBHOOK_SECRET:($billing[0][$prefix + "STRIPE_WEBHOOK_SECRET"] // $billing[0].STRIPE_WEBHOOK_SECRET // ""),
     STRIPE_XCONNECT_PAY_URL:($billing[0][$prefix + "STRIPE_XCONNECT_PAY_URL"] // $billing[0].STRIPE_XCONNECT_PAY_URL // "")} + $oauth[0] +
     (if ($zero[0].ZERO_SIGNING_PRIVATE_KEY // "") == "" and ($zero[0].ZERO_SIGNING_KEY_ID // "") == "" then {}
      else {XCONNECT_OVERLAY_SIGNING_PRIVATE_KEY:($zero[0].ZERO_SIGNING_PRIVATE_KEY | required(.)),
            XCONNECT_OVERLAY_SIGNING_KEY_ID:($zero[0].ZERO_SIGNING_KEY_ID | required(.))} end)
   elif $service == "content-service" then
     {KNOWLEDGE_REPO_PATH:($runtime.KNOWLEDGE_REPO_PATH | required(.)),
      KNOWLEDGE_REPO_URL:"https://github.com/ai-workspace-services/knowledge.git",KNOWLEDGE_REPO_REF:($runtime.KNOWLEDGE_REPO_REF // "main")}
   else {} end)' "$CLOUDFLARE_BOUNDARY_CONFIG" > "$temporary/environment.json"
jq -e 'type == "object" and length > 0 and all(to_entries[]; (.key | test("^[A-Z][A-Z0-9_]*$")) and (.value | type == "string" and (contains("\u0000") | not)))' "$temporary/environment.json" >/dev/null
while IFS= read -r key; do
  # Preserve trailing newlines in PEMs/credentials across command substitution.
  value="$(jq -jr --arg key "$key" '.[$key]' "$temporary/environment.json" && printf '.')"
  value="${value%.}"
  masked="${value//%/%25}"; masked="${masked//$'\r'/%0D}"; masked="${masked//$'\n'/%0A}"
  [[ -z "$masked" ]] || printf '::add-mask::%s\n' "$masked"
  delimiter="runtime_$(openssl rand -hex 16)"
  printf '%s<<%s\n%s\n%s\n' "$key" "$delimiter" "$value" "$delimiter" >> "$GITHUB_ENV"
done < <(jq -r 'keys[]' "$temporary/environment.json")
echo 'Selected Cloud Run runtime inputs prepared; no Provider operation performed.'
