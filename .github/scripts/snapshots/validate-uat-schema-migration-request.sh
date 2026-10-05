#!/usr/bin/env bash
set -euo pipefail

apply_schema="${APPLY_ACCOUNTS_SCHEMA_MIGRATION:-false}"
adopt_baseline="${ADOPT_ACCOUNTS_BASELINE:-false}"
expected="${ACCOUNTS_SCHEMA_EXPECTED_VERSION:-}"
target="${ACCOUNTS_SCHEMA_TARGET_VERSION:-}"
checksum="${ACCOUNTS_SCHEMA_SHA256:-}"

if [[ "${ENABLE_MIGRATION:-false}" == true ]]; then
  if [[ "${DEPLOY_ENV:-}" != uat || "${apply_schema}" != false || "${adopt_baseline}" != false ]]; then
    echo '::error::Explicit one-time import requires UAT and cannot be combined with schema migration or baseline adoption.' >&2
    exit 2
  fi
  # Validate nonsecret dispatch inputs before Vault, tagging or builds. The
  # shared control validator owns the credential/SQL rules; no DB logic here.
  python3 - "$(dirname "${BASH_SOURCE[0]}")/../environment-upgrade/validate_operation.py" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location('guard', sys.argv[1])
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
config = json.loads(os.environ.get('DATA_IMPORT_CONFIG_JSON') or '{}')
guard.validate_config(config, 'legacy_import')
guard.require(type(config.get('dry_run', True)) is bool, 'dry_run must be a JSON boolean')
guard.require(config.get('confirm_legacy_import', True) is True, 'explicit import confirmation cannot be false')
PY
elif [[ "${ENABLE_MIGRATION:-false}" != false ]]; then
  echo '::error::ENABLE_MIGRATION must be true or false.' >&2
  exit 2
fi

case "${adopt_baseline}" in
  false) ;;
  true)
    if [[ "${apply_schema}" != "false" || -n "${expected}${target}${checksum}" ]]; then
      echo "::error::UAT baseline adoption cannot be combined with another schema migration." >&2
      exit 2
    fi
    if [[ "${DEPLOY_ENV:-}" != "uat" || -n "${SNAPSHOT_REPOS:-}" || -n "${SNAPSHOT_SOURCE_REF:-}" || "${ENABLE_MIGRATION:-}" != "false" ]]; then
      echo "::error::UAT baseline adoption requires a full main snapshot with data migration disabled." >&2
      exit 2
    fi
    echo "Validated UAT expand-only Accounts baseline adoption."
    exit 0
    ;;
  *) echo "::error::ADOPT_ACCOUNTS_BASELINE must be true or false." >&2; exit 2 ;;
esac

case "${apply_schema}" in
  false)
    if [[ -n "${expected}${target}${checksum}" ]]; then
      echo "::error::Schema migration inputs require APPLY_ACCOUNTS_SCHEMA_MIGRATION=true." >&2
      exit 2
    fi
    exit 0
    ;;
  true) ;;
  *) echo "::error::APPLY_ACCOUNTS_SCHEMA_MIGRATION must be true or false." >&2; exit 2 ;;
esac

if [[ "${DEPLOY_ENV:-}" != "uat" || -n "${SNAPSHOT_REPOS:-}" || -n "${SNAPSHOT_SOURCE_REF:-}" ]]; then
  echo "::error::Accounts schema migration requires an unfiltered UAT main snapshot." >&2
  exit 2
fi
if [[ "${ENABLE_MIGRATION:-}" != "false" ]]; then
  echo "::error::Set enable_migration=false; the data-merge migration is incompatible with schema-only rollout." >&2
  exit 2
fi
if [[ ! "${expected}" =~ ^[0-9]+$ || ! "${target}" =~ ^[0-9]+$ || "${target}" -le "${expected}" ]]; then
  echo "::error::Expected and target schema versions must be increasing numeric values." >&2
  exit 2
fi
if [[ ! "${checksum}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "::error::ACCOUNTS_SCHEMA_SHA256 must be a lowercase SHA-256 digest." >&2
  exit 2
fi

echo "Validated UAT schema-only migration request: ${expected} -> ${target}."
