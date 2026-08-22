#!/usr/bin/env bash
set -euo pipefail

# Unit test for Supabase runtime URI normalization and Cloud Run contract.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
orchestrator="${repo_root}/scripts/serverless_uat/deploy_orchestrator.py"

python3 - "${orchestrator}" <<'EOF'
import importlib.util
import json
import sys
import urllib.request
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "deploy_orchestrator",
    sys.argv[1],
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Regression guard: when Vault authentication is present, fetch_vault_path must
# execute the HTTP read and return a dict. A previous merge accidentally placed
# that code after billing_secret(), so every authenticated fetch returned None
# and deployment later failed with AttributeError: NoneType has no attribute get.
mod.VAULT_TOKEN = "test-token"
mod.VAULT_ADDR = "https://vault.example"

class FakeResponse:
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return json.dumps({"data": {"data": {"PROJECT_REF": "test-ref"}}}).encode()

def fake_urlopen(request, timeout):
    assert request.full_url == "https://vault.example/v1/kv/data/uat/serverless/supabase"
    assert request.get_header("X-vault-token") == "test-token"
    assert timeout == 10
    return FakeResponse()

original_urlopen = urllib.request.urlopen
urllib.request.urlopen = fake_urlopen
try:
    fetched = mod.fetch_vault_path("kv/data/uat/serverless/supabase")
finally:
    urllib.request.urlopen = original_urlopen
assert fetched == {"PROJECT_REF": "test-ref"}, fetched

normalize = mod.normalize_runtime_database_uri

# Case 1: Session pooler with discrete password needing percent-encoding
s1 = {
    "PROJECT_REF": "iqkxspmhcfqmhkbjdoms",
    "DATABASE_USERNAME": "postgres",
    "DATABASE_PASSWORD": "P@ssw0rd!#%^&*()",
    "DATABASE_SESSION_POOLER_URL": "postgres://postgres.iqkxspmhcfqmhkbjdoms:placeholder@aws-0-ap-northeast-1.pooler.supabase.com:6543/postgres",
}
res1 = normalize(s1)
assert "postgres.iqkxspmhcfqmhkbjdoms" in res1, f"Expected tenant prefix in {res1}"
assert "P%40ssw0rd%21%23%25%5E%26%2A%28%29" in res1, f"Expected encoded password in {res1}"

# Case 2: Pooler without explicit username in secrets (derived from userinfo)
s2 = {
    "PROJECT_REF": "iqkxspmhcfqmhkbjdoms",
    "DATABASE_PASSWORD": "mysecretpassword",
    "DATABASE_SESSION_POOLER_URL": "postgres://postgres.iqkxspmhcfqmhkbjdoms:rawpass@aws-0-ap-northeast-1.pooler.supabase.com:6543/postgres",
}
res2 = normalize(s2)
assert res2 == "postgres://postgres.iqkxspmhcfqmhkbjdoms:mysecretpassword@aws-0-ap-northeast-1.pooler.supabase.com:6543/postgres"

# Case 3: Direct connection without pooler tenant suffix
s3 = {
    "PROJECT_REF": "iqkxspmhcfqmhkbjdoms",
    "DATABASE_USERNAME": "postgres",
    "DATABASE_PASSWORD": "mysecretpassword",
    "DATABASE_DIRECT_URL": "postgres://postgres:rawpass@db.iqkxspmhcfqmhkbjdoms.supabase.co:5432/postgres",
}
res3 = normalize(s3)
assert res3 == "postgres://postgres:mysecretpassword@db.iqkxspmhcfqmhkbjdoms.supabase.co:5432/postgres"

# Case 4: Base username 'postgres' with pooler host and PROJECT_REF appends project ref
s4 = {
    "PROJECT_REF": "pvdhywdfuupxydkflquq",
    "DATABASE_USERNAME": "postgres",
    "DATABASE_PASSWORD": "mysecretpassword",
    "DATABASE_SESSION_POOLER_URL": "postgres://postgres:rawpass@aws-0-ap-northeast-1.pooler.supabase.com:6543/postgres",
}
res4 = normalize(s4)
assert "postgres.pvdhywdfuupxydkflquq:mysecretpassword@" in res4, f"Expected tenant prefix in {res4}"

print("Supabase runtime URI normalization tests: PASS")
EOF

echo "supabase_runtime_uri_normalization_test: PASS"
