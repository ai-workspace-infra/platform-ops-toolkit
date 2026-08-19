#!/usr/bin/env bash
set -euo pipefail

backend="${ACCOUNTS_TARGET_BACKEND:-vps}"
mode="${ACCOUNTS_MIGRATION_MODE:-data}"
project_ref="${SUPABASE_PROJECT_REF:-}"

case "${backend}:${mode}" in
  vps:data)
    echo "Migration target validated: VPS self-hosted PostgreSQL data flow."
    ;;
  supabase:metadata|supabase:metadata_and_data)
    if [[ ! "${project_ref}" =~ ^[a-z0-9]{20}$ ]]; then
      echo "::error::SUPABASE_PROJECT_REF must be a 20-character lowercase project ref." >&2
      exit 1
    fi
    echo "Migration target validated: Supabase Cloud one-way metadata/data flow (${project_ref})."
    ;;
  *)
    echo "::error::Unsupported Accounts migration combination: backend=${backend}, mode=${mode}." >&2
    echo "Allowed combinations are backend=vps/mode=data or backend=supabase/mode=metadata|metadata_and_data." >&2
    exit 1
    ;;
esac
