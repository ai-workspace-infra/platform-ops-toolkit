#!/usr/bin/env python3
"""Ensure Observability jobs using Vault can request GitHub OIDC tokens."""

from pathlib import Path
import yaml

root = Path(__file__).resolve().parents[3]
workflow = yaml.safe_load((root / ".github/workflows/observability-server.yml").read_text())

for job_name in ("historical_data", "verify_stores", "verify_target", "dns_switch"):
    permissions = workflow["jobs"][job_name].get("permissions", {})
    assert permissions.get("id-token") == "write", (
        f"{job_name} must have id-token: write for Vault JWT authentication"
    )
    assert permissions.get("contents") == "read", (
        f"{job_name} should retain only read access to repository contents"
    )

print("observability_oidc_permissions_contract: PASS")
