#!/usr/bin/env bash
set -euo pipefail

# Web SaaS upgrade acceptance that does not depend on DNS.
#
# UAT repair run 37171674829 upgraded a host with dns_mode=none: DB Init
# succeeded, then "DNS Update" and "Web SaaS status" were both skipped, because
# every post-deploy check hung off switch_dns. Nothing proved that the new
# Accounts and Console were serving, which images were running, or that the
# existing users and subscriptions survived the upgrade. This script supplies
# that proof per host, over SSH by CMDB address, with or without a DNS change.
#
#   baseline  Before the GitOps tags move. Records a per-row fingerprint of the
#             rows that define login and entitlement (users, identities,
#             subscriptions) and the schema_migrations state. The fingerprint
#             stays on the host (root, 0700): no row value or row hash is ever
#             printed or uploaded -- only counts are.
#   verify    After deploy + DB init. Waits for Accounts /readyz and /api/ping
#             and Console / to answer from inside the host (no DNS, no TLS),
#             requires the running managed images to carry DEPLOY_TAG, requires
#             schema_migrations clean and not older than the baseline, and
#             requires every baseline row to still exist unchanged.
#
# Deliberately NOT proven here, and reported as such in the summary:
#   - an interactive login with an original account (that needs a credential
#     this pipeline must not hold);
#   - subscription preservation when the baseline held zero subscription rows
#     (an empty set is trivially preserved).
#
# Env: MATRIX_HOST, CMDB_FILE (default cmdb/cmdb.json), ACCEPTANCE_RUN_ID
# (default GITHUB_RUN_ID), DEPLOY_TAG (verify; empty skips the tag check),
# EXPECTED_ACCOUNTS_SCHEMA_VERSION (verify; optional exact version),
# WEB_SAAS_ACCEPTANCE_TIMEOUT_SECONDS (300), WEB_SAAS_ACCEPTANCE_POLL_SECONDS (5).

. "$(dirname "${BASH_SOURCE[0]}")/../../lib/require-env.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/cmdb-ssh-login.sh"
require_env MATRIX_HOST

mode="${1:-}"
case "${mode}" in
  baseline|verify) ;;
  *) echo "::error::usage: $(basename "$0") baseline|verify" >&2; exit 2 ;;
esac

run_id="${ACCEPTANCE_RUN_ID:-${GITHUB_RUN_ID:-}}"
[[ "${run_id}" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "::error::ACCEPTANCE_RUN_ID (or GITHUB_RUN_ID) must be set to a plain identifier." >&2
  exit 2
}
timeout_seconds="${WEB_SAAS_ACCEPTANCE_TIMEOUT_SECONDS:-300}"
poll_seconds="${WEB_SAAS_ACCEPTANCE_POLL_SECONDS:-5}"
[[ "${timeout_seconds}" =~ ^[0-9]+$ && "${poll_seconds}" =~ ^[0-9]+$ ]] || {
  echo "::error::Acceptance timeout and poll interval must be non-negative integers." >&2
  exit 2
}
deploy_tag="${DEPLOY_TAG:-}"
expected_version="${EXPECTED_ACCOUNTS_SCHEMA_VERSION:-}"

cmdb_file="${CMDB_FILE:-cmdb/cmdb.json}"
[[ -f "${cmdb_file}" ]] || { echo "::error::CMDB file not found: ${cmdb_file}" >&2; exit 2; }
host_ip="$(jq -r --arg host "${MATRIX_HOST}" '.[$host].ip // empty' "${cmdb_file}")"
[[ -n "${host_ip}" && "${host_ip}" != "null" ]] || {
  echo "::error::No IP address for ${MATRIX_HOST} in ${cmdb_file}" >&2
  exit 2
}
cmdb_ssh_login "${cmdb_file}" "${MATRIX_HOST}"

ssh_opts=(
  -i ~/.ssh/id_deploy
  -o BatchMode=yes
  -o ConnectTimeout=15
  -o StrictHostKeyChecking=no
)

# Everything below runs on the host as root. It reads the account database
# through `docker exec ... psql -U postgres` -- the same access path DB Init
# uses -- and never writes to it.
remote() { # <subcommand>
  ssh "${ssh_opts[@]}" "${ssh_user}@${host_ip}" "${sudo_prefix}bash -s -- $1 ${run_id}" <<'REMOTE'
set -euo pipefail
cmd="$1"
run_id="$2"
root=/var/lib/platform-ops/upgrade-acceptance
dir="${root}/${run_id}"
pg=web-saas-postgresql
tables="users identities subscriptions"
# Columns that define "the same account, able to log in, with the same rights
# and entitlement". Volatile columns (updated_at, version, last_active_at,
# session tokens) are excluded on purpose: they change on every login.
declare -A candidates=(
  [users]="username,email,password,role,level,groups,permissions,mfa_enabled,mfa_totp_secret,active,subscription_valid_from,subscription_valid_until"
  [identities]="provider,external_id,user_uuid"
  [subscriptions]="user_uuid,provider,payment_method,kind,plan_id,external_id,status,cancelled_at,created_at"
)

q() { docker exec -i -e PGTZ=UTC "${pg}" psql -U postgres -d account -XAtq -v ON_ERROR_STOP=1 -c "$1"; }

db_present() {
  [ "$(docker inspect -f '{{.State.Status}}' "${pg}" 2>/dev/null)" = running ] || return 1
  [ "$(docker exec -i "${pg}" psql -U postgres -d postgres -XAtq -c "SELECT 1 FROM pg_database WHERE datname = 'account'" 2>/dev/null)" = 1 ]
}

table_present() { [ "$(q "SELECT to_regclass('public.$1') IS NOT NULL")" = t ]; }

migration_state() {
  if table_present schema_migrations; then
    local state
    state="$(q "SELECT version::text || ':' || dirty::text FROM public.schema_migrations LIMIT 1")"
    echo "${state:-empty}"
  else
    echo absent
  fi
}

present_columns() { # <table> <candidate csv>; keeps candidate order
  q "SELECT coalesce(string_agg(t.c, ',' ORDER BY t.o), '') FROM unnest(string_to_array('$2', ',')) WITH ORDINALITY AS t(c, o) WHERE EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = '$1' AND column_name = t.c)"
}

row_fingerprints() { # <table> <column csv> -> "<uuid> <md5>" sorted
  local expr="" c cols
  IFS=, read -ra cols <<<"$2"
  for c in "${cols[@]}"; do expr+="${expr:+, }coalesce(${c}::text, '<null>')"; done
  [ -n "${expr}" ] || expr="''"
  q "SELECT uuid::text || ' ' || md5(concat_ws(chr(31), ${expr})) FROM public.$1" | LC_ALL=C sort
}

users_with_password() {
  if table_present users; then q "SELECT count(*) FROM public.users WHERE coalesce(password, '') <> ''"; else echo absent; fi
}

ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" 2>/dev/null | awk '{print $1}'; }

# HTTP over bash /dev/tcp to the container's bridge address: needs neither DNS,
# nor a certificate, nor curl in the image or on the host.
http_status() { # <container> <port> <path>
  local ip status
  ip="$(ip_of "$1")"
  [ -n "${ip}" ] || { echo none; return; }
  status="$(timeout 10 bash -c 'exec 3<>"/dev/tcp/$0/$1" && printf "GET %s HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n" "$2" >&3 && head -n1 <&3' "${ip}" "$2" "$3" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)"
  echo "${status:-none}"
}

case "${cmd}" in
  baseline)
    mkdir -p "${root}" && chmod 700 "${root}"
    find "${root}" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>/dev/null || true
    # The first capture of a run is the pre-upgrade truth. A re-run of this job
    # after the tags moved must not replace it with post-upgrade state.
    if [ -s "${dir}/summary" ]; then
      echo "baseline=kept"
      cat "${dir}/summary"
      exit 0
    fi
    tmp="$(mktemp -d "${root}/.capture.XXXXXX")"
    if ! db_present; then
      echo "state=absent" >"${tmp}/summary"
    else
      {
        echo "state=present"
        echo "migration=$(migration_state)"
        echo "users_with_password=$(users_with_password)"
      } >"${tmp}/summary"
      for t in ${tables}; do
        if table_present "${t}"; then
          present_columns "${t}" "${candidates[${t}]}" >"${tmp}/${t}.cols"
          row_fingerprints "${t}" "$(cat "${tmp}/${t}.cols")" >"${tmp}/${t}.rows"
          echo "rows_${t}=$(wc -l <"${tmp}/${t}.rows")" >>"${tmp}/summary"
        else
          echo "rows_${t}=absent" >>"${tmp}/summary"
        fi
      done
    fi
    chmod -R go-rwx "${tmp}"
    rm -rf "${dir}"
    mv "${tmp}" "${dir}"
    echo "baseline=captured"
    cat "${dir}/summary"
    ;;
  probe)
    for c in web-saas-accounts web-saas-console web-saas-billing; do
      if ref="$(docker inspect -f '{{.Config.Image}}' "${c}" 2>/dev/null)"; then
        id="$(docker inspect -f '{{.Image}}' "${c}")"
        digests="$(docker image inspect -f '{{join .RepoDigests ","}}' "${id}" 2>/dev/null || true)"
        echo "image ${c} ${ref} ${digests:-none}"
      else
        echo "image ${c} missing none"
      fi
    done
    echo "http accounts_readyz $(http_status web-saas-accounts 8080 /readyz)"
    echo "http accounts_ping $(http_status web-saas-accounts 8080 /api/ping)"
    echo "http console_root $(http_status web-saas-console 3000 /)"
    ;;
  compare)
    if [ ! -s "${dir}/summary" ]; then echo "baseline=missing"; exit 0; fi
    sed 's/^/baseline_/' "${dir}/summary"
    if ! db_present; then echo "post_db=absent"; exit 0; fi
    echo "post_db=present"
    echo "post_migration=$(migration_state)"
    echo "post_users_with_password=$(users_with_password)"
    for t in ${tables}; do
      [ -f "${dir}/${t}.rows" ] || continue
      before="$(wc -l <"${dir}/${t}.rows")"
      if ! table_present "${t}"; then
        echo "table ${t} before=${before} after=absent missing=${before} changed=0 dropped_columns=0"
        continue
      fi
      cols="$(cat "${dir}/${t}.cols")"
      if [ "$(present_columns "${t}" "${cols}")" != "${cols}" ]; then
        echo "table ${t} before=${before} after=unknown missing=0 changed=0 dropped_columns=1"
        continue
      fi
      row_fingerprints "${t}" "${cols}" >"${dir}/${t}.after"
      chmod 600 "${dir}/${t}.after"
      after="$(wc -l <"${dir}/${t}.after")"
      missing="$(LC_ALL=C join -v1 "${dir}/${t}.rows" "${dir}/${t}.after" | wc -l)"
      changed="$(LC_ALL=C join "${dir}/${t}.rows" "${dir}/${t}.after" | awk '$2 != $3' | wc -l)"
      echo "table ${t} before=${before} after=${after} missing=${missing} changed=${changed} dropped_columns=0"
    done
    ;;
esac
REMOTE
}

summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$@" >>"${GITHUB_STEP_SUMMARY}"; return 0; }

if ! ssh_probe="$(ssh "${ssh_opts[@]}" "${ssh_user}@${host_ip}" "${sudo_prefix}true" 2>&1)"; then
  echo "::error::Cannot open an authenticated SSH session to ${ssh_user}@${host_ip} (${MATRIX_HOST}): ${ssh_probe}" >&2
  exit 1
fi

if [[ "${mode}" == baseline ]]; then
  # Bootstrap runs on the same host in parallel and may restart Docker; give a
  # dropped psql/SSH session a bounded second chance. The capture is atomic
  # (temp dir + rename), so a retry never mixes two partial captures.
  for attempt in 1 2 3; do
    out="$(remote baseline 2>&1)" && break
    printf '%s\n' "${out}" >&2
    if (( attempt == 3 )); then
      echo "::error::Could not capture the pre-upgrade baseline on ${MATRIX_HOST}; refusing to move GitOps tags without it." >&2
      exit 1
    fi
    sleep "${WEB_SAAS_BASELINE_RETRY_SECONDS:-15}"
  done
  printf '%s\n' "${out}"
  summary "### Web SaaS pre-upgrade baseline (${MATRIX_HOST})" '' '```' "${out}" '```'
  exit 0
fi

# ---- verify: services and images -------------------------------------------
failures=()
probe_failures() { # <probe output>
  local kind name a b expected
  local -a problems=()
  declare -A seen=()
  while read -r kind name a b; do
    [[ -n "${name:-}" ]] && seen["${kind} ${name}"]=1
    case "${kind}" in
      image)
        if [[ "${a}" == missing ]]; then
          problems+=("${name} container is missing")
        elif [[ -n "${deploy_tag}" && "${a}" != *":${deploy_tag}" ]]; then
          problems+=("${name} runs ${a}, expected tag ${deploy_tag}")
        fi ;;
      http)
        case "${name}" in
          console_root) [[ "${a}" =~ ^[23][0-9][0-9]$ ]] || problems+=("Console / answered ${a}") ;;
          *) [[ "${a}" == 200 ]] || problems+=("Accounts ${name#accounts_} answered ${a}") ;;
        esac ;;
    esac
  done <<<"$1"
  # A probe that could not run prints none of these lines; silence is a failure.
  for expected in "image web-saas-accounts" "image web-saas-console" "image web-saas-billing" \
    "http accounts_readyz" "http accounts_ping" "http console_root"; do
    [[ -n "${seen[${expected}]:-}" ]] || problems+=("probe returned no '${expected}' result")
  done
  [[ "${#problems[@]}" -eq 0 ]] || printf '%s\n' "${problems[@]}"
}

deadline=$(( $(date +%s) + timeout_seconds ))
while :; do
  probe="$(remote probe 2>&1)" || probe="probe failed: ${probe}"
  problems="$(probe_failures "${probe}")"
  [[ -z "${problems}" ]] && break
  [[ $(date +%s) -lt ${deadline} ]] || break
  sleep "${poll_seconds}"
done
printf '%s\n' "${probe}"
if [[ -n "${problems}" ]]; then
  while IFS= read -r p; do failures+=("${p}"); done <<<"${problems}"
fi

# ---- verify: database state and data preservation --------------------------
if ! compare="$(remote compare 2>&1)"; then
  printf '%s\n' "${compare}" >&2
  failures+=("could not read the post-upgrade database state")
  compare=""
fi
printf '%s\n' "${compare}"
value() { awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }' <<<"${compare}"; }

baseline_state="$(value baseline_state)"
before_migration="$(value baseline_migration)"
after_migration="$(value post_migration)"
notes=()

if grep -qx 'baseline=missing' <<<"${compare}"; then
  failures+=("no pre-upgrade baseline for run ${run_id} on this host; data preservation cannot be proven")
elif [[ "${baseline_state}" == absent ]]; then
  notes+=("fresh host: no account database existed before this run, so there was no data to preserve")
fi
if grep -qx 'post_db=absent' <<<"${compare}"; then
  failures+=("the account database is not reachable after the upgrade")
fi

if [[ -n "${after_migration}" && "${after_migration}" != absent ]]; then
  if [[ "${after_migration}" != *:false ]]; then
    failures+=("schema_migrations is ${after_migration}: a dirty or empty migration state is never accepted")
  fi
  if [[ -n "${expected_version}" && "${after_migration%%:*}" != "${expected_version}" ]]; then
    failures+=("schema_migrations version ${after_migration%%:*}, expected ${expected_version}")
  fi
fi
if [[ "${before_migration}" =~ ^[0-9]+: ]]; then
  if [[ ! "${after_migration}" =~ ^[0-9]+: ]]; then
    failures+=("schema_migrations was ${before_migration} before the upgrade and is ${after_migration:-unknown} after it")
  elif (( ${after_migration%%:*} < ${before_migration%%:*} )); then
    failures+=("schema_migrations went backwards: ${before_migration%%:*} -> ${after_migration%%:*}")
  fi
fi

table_rows=()
while read -r _ t before after missing changed dropped; do
  before="${before#before=}"; after="${after#after=}"
  missing="${missing#missing=}"; changed="${changed#changed=}"; dropped="${dropped#dropped_columns=}"
  table_rows+=("| ${t} | ${before} | ${after} | ${missing} | ${changed} |")
  (( missing == 0 )) || failures+=("${t}: ${missing} of ${before} pre-upgrade rows are gone")
  (( changed == 0 )) || failures+=("${t}: ${changed} of ${before} pre-upgrade rows changed login/entitlement fields")
  (( dropped == 0 )) || failures+=("${t}: a fingerprinted column was dropped by the upgrade")
done < <(grep '^table ' <<<"${compare}")

subscriptions_before="$(value baseline_rows_subscriptions)"
if [[ "${baseline_state}" == present && ( "${subscriptions_before}" == 0 || "${subscriptions_before}" == absent ) ]]; then
  notes+=("subscription preservation is vacuous: the baseline held ${subscriptions_before} subscription rows; the promotion gate still needs a controlled non-empty sample")
  echo "::warning::Subscription preservation not demonstrated on ${MATRIX_HOST}: baseline held ${subscriptions_before} subscription rows."
fi
notes+=("login with an original account is not exercised by this job; it remains a manual promotion gate")

summary "### Web SaaS upgrade acceptance (${MATRIX_HOST})" '' \
  "| Check | Result |" "| --- | --- |" \
  "| schema_migrations before → after | \`${before_migration:-n/a}\` → \`${after_migration:-n/a}\` |" \
  "| users with password before → after | \`$(value baseline_users_with_password)\` → \`$(value post_users_with_password)\` |" \
  '' "| Table | Rows before | Rows after | Missing | Changed |" "| --- | --- | --- | --- | --- |"
[[ "${#table_rows[@]}" -gt 0 ]] && summary "${table_rows[@]}"
summary '' "Running images and HTTP probes:" '```' "${probe}" '```'
for n in "${notes[@]}"; do
  echo "NOTE: ${n}"
  summary "- ${n}"
done

if [[ "${#failures[@]}" -gt 0 ]]; then
  for f in "${failures[@]}"; do
    echo "::error::Web SaaS upgrade acceptance (${MATRIX_HOST}): ${f}" >&2
    summary "- **FAILED:** ${f}"
  done
  exit 1
fi
echo "Web SaaS upgrade acceptance passed on ${MATRIX_HOST}."
