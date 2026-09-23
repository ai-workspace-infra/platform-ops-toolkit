#!/usr/bin/env bash
set -euo pipefail

apply_schema="${APPLY_ACCOUNTS_SCHEMA_MIGRATION:-false}"
adopt_baseline="${ADOPT_ACCOUNTS_BASELINE:-false}"
expected="${ACCOUNTS_SCHEMA_EXPECTED_VERSION:-}"
target="${ACCOUNTS_SCHEMA_TARGET_VERSION:-}"
checksum="${ACCOUNTS_SCHEMA_SHA256:-}"

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
