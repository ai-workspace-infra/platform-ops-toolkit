#!/usr/bin/env bash
set -euo pipefail

# Integration test for platform-ops_web-saas-upgrade-acceptance.sh against a
# real PostgreSQL. The remote half of the script (baseline/compare SQL, the
# host-side fingerprint files) runs unmodified; only `docker exec` is shimmed to
# a local psql and the root-only state directory is redirected to a temp dir.
# The HTTP/image probe needs live containers, so its answer is canned here and
# its pass/fail rules are covered by web_saas_upgrade_acceptance_test.sh.
#
# Needs a disposable server: PGHOST must be loopback, and the `account`
# database on it is dropped and recreated. CI runs it against the postgres:17
# service container of validate-release-pr.yml.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/scripts/platform-ops/observe/platform-ops_web-saas-upgrade-acceptance.sh"

export PGHOST="${PGHOST:-127.0.0.1}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}"
case "${PGHOST}" in
  127.0.0.1|localhost|::1) ;;
  *) echo "refusing to drop the account database on non-loopback PGHOST=${PGHOST}" >&2; exit 2 ;;
esac

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
mkdir -p "${workdir}/bin" "${workdir}/state"
printf '{"web-saas-uat":{"ip":"192.0.2.10"}}' >"${workdir}/cmdb.json"

# docker: only what the remote script needs from web-saas-postgresql.
cat >"${workdir}/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  inspect)
    [[ "$3" == *State.Status* && "$4" == web-saas-postgresql && -z "${FAKE_PG_DOWN:-}" ]] && { echo running; exit 0; }
    exit 1 ;;
  exec)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -i) shift ;;
        -e) export "$2"; shift 2 ;;
        web-saas-postgresql) shift; break ;;
        *) echo "unexpected docker exec arg $1" >&2; exit 2 ;;
      esac
    done
    [ "$1" = psql ] || exit 2
    shift
    exec psql -h "${PGHOST}" -p "${PGPORT}" "$@" ;;
esac
exit 1
EOF

# ssh: run the remote script locally (minus sudo), except the canned probe.
cat >"${workdir}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${!#}"
[[ "${cmd}" == *" true" || "${cmd}" == true ]] && exit 0
read -r -a words <<<"${cmd#sudo -n }"
sub="${words[3]}"; run="${words[4]}"
if [[ "${sub}" == probe ]]; then
  cat >/dev/null
  cat <<PROBE
image web-saas-accounts ghcr.io/ai-workspace-services/accounts:${FAKE_TAG} ghcr.io/ai-workspace-services/accounts@sha256:aaaa
image web-saas-console ghcr.io/ai-workspace-services/console:${FAKE_TAG} ghcr.io/ai-workspace-services/console@sha256:bbbb
image web-saas-billing ghcr.io/ai-workspace-services/billing-service:${FAKE_TAG} ghcr.io/ai-workspace-services/billing-service@sha256:cccc
http accounts_readyz 200
http accounts_ping 200
http console_root 307
PROBE
  exit 0
fi
sed "s#/var/lib/platform-ops/upgrade-acceptance#${FAKE_STATE_ROOT}#" | bash -s -- "${sub}" "${run}"
EOF
chmod +x "${workdir}/bin/docker" "${workdir}/bin/ssh"

sql() { psql -XAtq -v ON_ERROR_STOP=1 -d account -c "$1"; }

reset_account_db() {
  psql -XAtq -d postgres -c "DROP DATABASE IF EXISTS account" >/dev/null
  psql -XAtq -d postgres -c "CREATE DATABASE account" >/dev/null
}

# A pre-2026091301 shape: users has no subscription validity columns yet.
seed_old_release() {
  reset_account_db
  psql -XAtq -v ON_ERROR_STOP=1 -d account >/dev/null <<'SQL'
CREATE TABLE schema_migrations (version bigint NOT NULL PRIMARY KEY, dirty boolean NOT NULL);
INSERT INTO schema_migrations VALUES (2026090802, false);
CREATE TABLE users (
  uuid uuid PRIMARY KEY, username text NOT NULL, password text NOT NULL, email text,
  role text NOT NULL DEFAULT 'user', level int NOT NULL DEFAULT 20,
  groups jsonb NOT NULL DEFAULT '[]', permissions jsonb NOT NULL DEFAULT '[]',
  mfa_enabled boolean NOT NULL DEFAULT false, mfa_totp_secret text, active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE identities (uuid uuid PRIMARY KEY, provider text NOT NULL, external_id text NOT NULL,
  user_uuid uuid NOT NULL REFERENCES users(uuid) ON DELETE CASCADE);
CREATE TABLE subscriptions (uuid uuid PRIMARY KEY, user_uuid uuid NOT NULL REFERENCES users(uuid) ON DELETE CASCADE,
  provider text NOT NULL, payment_method text NOT NULL DEFAULT 'paypal', kind text NOT NULL DEFAULT 'subscription',
  plan_id text, external_id text NOT NULL, status text NOT NULL DEFAULT 'pending', payment_qr text,
  meta jsonb NOT NULL DEFAULT '{}', created_at timestamptz NOT NULL DEFAULT '2026-09-01T00:00:00Z',
  updated_at timestamptz NOT NULL DEFAULT now(), cancelled_at timestamptz);
INSERT INTO users (uuid, username, password, email, role) VALUES
  ('11111111-1111-1111-1111-111111111111', 'alice', '$2a$10$fixturehashalice', 'alice@example.test', 'admin'),
  ('22222222-2222-2222-2222-222222222222', 'bob', '', 'bob@example.test', 'user');
INSERT INTO identities VALUES
  ('33333333-3333-3333-3333-333333333333', 'github', 'gh-42', '22222222-2222-2222-2222-222222222222');
INSERT INTO subscriptions (uuid, user_uuid, provider, plan_id, external_id, status) VALUES
  ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111', 'stripe', 'pro', 'sub_A', 'active'),
  ('55555555-5555-5555-5555-555555555555', '22222222-2222-2222-2222-222222222222', 'paypal', 'basic', 'I-B', 'cancelled');
SQL
}

run_mode() { # <mode> <run-id>; sets rc and out
  rc=0
  out="$(PATH="${workdir}/bin:${PATH}" FAKE_STATE_ROOT="${workdir}/state" FAKE_TAG=uat-daily-build-2026.10.04-r1 \
    MATRIX_HOST=web-saas-uat CMDB_FILE="${workdir}/cmdb.json" ACCEPTANCE_RUN_ID="$2" \
    DEPLOY_TAG=uat-daily-build-2026.10.04-r1 GITHUB_STEP_SUMMARY="${workdir}/summary.md" \
    WEB_SAAS_ACCEPTANCE_TIMEOUT_SECONDS=0 WEB_SAAS_ACCEPTANCE_POLL_SECONDS=0 \
    bash "${script}" "$1" 2>&1)" || rc=$?
}

pass=0
expect() { # <name> <condition...>
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); printf '  [PASS] %s\n' "${name}"; else
    printf '  [FAIL] %s (rc=%s)\n%s\n' "${name}" "${rc}" "$(sed 's/^/         /' <<<"${out}")"; exit 1; fi
}
has() { grep -Fq -- "$1" <<<"${out}"; }

echo "=== Web SaaS upgrade acceptance against PostgreSQL $(psql -XAtq -d postgres -c 'SHOW server_version') ==="

seed_old_release
run_mode baseline run-1
expect "baseline captures counts and migration state" \
  bash -c '[ "$0" = 0 ]' "${rc}"
for line in baseline=captured state=present migration=2026090802:false users_with_password=1 rows_users=2 rows_identities=1 rows_subscriptions=2; do
  expect "baseline reports ${line}" has "${line}"
done
expect "no row value or uuid leaves the host" \
  bash -c '! grep -Eq "alice|bob|sub_A|I-B|gh-42|1111|4444|fixturehash" <<<"$0"' "${out}"
expect "the fingerprint directory is root-only" \
  test "$(stat -c %a "${workdir}/state/run-1")" = 700

# A good upgrade: new columns, a newer migration, volatile churn, a new signup.
sql "ALTER TABLE users ADD COLUMN subscription_valid_from timestamptz, ADD COLUMN subscription_valid_until timestamptz, ADD COLUMN last_active_at timestamptz"
sql "UPDATE schema_migrations SET version = 2026092801"
sql "UPDATE users SET updated_at = now() + interval '1 hour', last_active_at = now()"
sql "UPDATE subscriptions SET updated_at = now() + interval '1 hour', meta = '{\"webhook\":1}'"
sql "INSERT INTO users (uuid, username, password) VALUES ('66666666-6666-6666-6666-666666666666', 'carol', 'x')"
run_mode verify run-1
expect "a lossless upgrade is accepted" bash -c '[ "$0" = 0 ]' "${rc}"
expect "summary shows subscriptions preserved" grep -Fq '| subscriptions | 2 | 2 | 0 | 0 |' "${workdir}/summary.md"
expect "summary shows the post-upgrade signup" grep -Fq '| users | 2 | 3 | 0 | 0 |' "${workdir}/summary.md"
expect "migration progression is reported" has "post_migration=2026092801:false"
expect "login stays a manual gate" has "login with an original account is not exercised"

run_mode baseline run-1
expect "re-running baseline keeps the pre-upgrade capture" has "baseline=kept"
expect "the kept capture still has the pre-upgrade user count" has "rows_users=2"

sql "DELETE FROM subscriptions WHERE external_id = 'sub_A'"
sql "UPDATE users SET role = 'user' WHERE username = 'alice'"
run_mode verify run-1
expect "lost or altered rows fail acceptance" bash -c '[ "$0" = 1 ]' "${rc}"
expect "a lost subscription is named" has "subscriptions: 1 of 2 pre-upgrade rows are gone"
expect "a changed role is named" has "users: 1 of 2 pre-upgrade rows changed login/entitlement fields"

sql "UPDATE schema_migrations SET dirty = true"
run_mode verify run-1
expect "a dirty migration fails acceptance" has "a dirty or empty migration state is never accepted"

sql "UPDATE schema_migrations SET dirty = false, version = 2026080101"
run_mode verify run-1
expect "a migration rollback fails acceptance" has "schema_migrations went backwards: 2026090802 -> 2026080101"

sql "ALTER TABLE subscriptions DROP COLUMN plan_id"
run_mode verify run-1
expect "dropping a fingerprinted column fails acceptance" has "subscriptions: a fingerprinted column was dropped"

run_mode verify run-unknown
expect "verify without a baseline fails" has "no pre-upgrade baseline for run run-unknown"

# Fresh host: nothing to preserve before, a freshly initialized database after.
psql -XAtq -d postgres -c "DROP DATABASE IF EXISTS account" >/dev/null
run_mode baseline run-2
expect "a host without an account database records state=absent" has "state=absent"
seed_old_release
run_mode verify run-2
expect "a fresh host is accepted with an explicit note" bash -c '[ "$0" = 0 ]' "${rc}"
expect "the fresh-host note is printed" has "fresh host: no account database existed before this run"

# Vacuous subscription preservation is accepted but loudly flagged.
sql "DELETE FROM subscriptions"
run_mode baseline run-3
run_mode verify run-3
expect "zero baseline subscriptions passes" bash -c '[ "$0" = 0 ]' "${rc}"
expect "zero baseline subscriptions raises a warning" has "::warning::Subscription preservation not demonstrated"

echo "web_saas_upgrade_acceptance_postgres_test: ${pass} checks passed"
