#!/usr/bin/env python3
"""Validate the selfhost orchestrator against the selected GitOps contract."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"GitOps selfhost contract invalid: {message}")


def main() -> int:
    config_path = os.environ.get("GITOPS_ROUTING_CONFIG")
    if not config_path:
        fail("GITOPS_ROUTING_CONFIG is required")

    manifest_path = Path(config_path)
    if not manifest_path.is_file():
        fail(f"declaration not found: {manifest_path}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    metadata = manifest.get("metadata", {})
    spec = manifest.get("spec", {})
    runtime = spec.get("runtime", {})
    routing = runtime.get("routing", {})
    dns = routing.get("dns", {})
    weights = routing.get("weight", {})
    services = runtime.get("services", {})
    data = runtime.get("data", {})
    migration = data.get("migration", {})

    if manifest.get("kind") != "EdgeRoutingConfig":
        fail("kind must be EdgeRoutingConfig")
    if metadata.get("name") != "web-saas" or metadata.get("project") != "svc.plus":
        fail("metadata must identify the svc.plus web-saas declaration")
    if metadata.get("mode") != "selfhost":
        fail("metadata.mode must be selfhost")
    if runtime.get("mode") != "selfhost":
        fail("spec.runtime.mode must be selfhost")

    expected_environment = os.environ.get("EXPECTED_ENV", "uat")
    if metadata.get("environment") != expected_environment:
        fail(f"metadata.environment must be {expected_environment}")

    expected_target_zone = os.environ.get("EXPECTED_TARGET_DOMAIN_BASE", "")
    expected_environment_zone = "svc.plus" if expected_environment == "prod" else "onwalk.net"
    if expected_target_zone and expected_target_zone != expected_environment_zone:
        fail(
            f"selfhost {expected_environment} routing requires "
            f"target_domain_base={expected_environment_zone}"
        )

    if dns.get("control_plane") != "cloudflare-dns":
        fail("runtime.routing.dns.control_plane must be cloudflare-dns")
    if dns.get("ttl_seconds") != 60:
        fail("runtime.routing.dns.ttl_seconds must be 60")
    if routing.get("load-balancer", {}).get("strategy") != "dns-only":
        fail("runtime.routing.load-balancer.strategy must be dns-only")
    if weights != {"selfhost": 100, "serverless": 0}:
        fail("runtime.routing.weight must be selfhost=100 and serverless=0")

    expected_services = {"console", "accounts", "content", "billing"}
    if set(services) != expected_services:
        fail("runtime.services must define console, accounts, content, and billing")
    for service, targets in services.items():
        if targets.get("selfhost") != "vps-full-stack":
            fail(f"runtime.services.{service}.selfhost must be vps-full-stack")

    if data.get("primary") != "selfhost":
        fail("runtime.data.primary must be selfhost")
    if data.get("replica") != "serverless":
        fail("runtime.data.replica must be serverless")
    if data.get("providers", {}).get("selfhost") != "self-managed-postgresql":
        fail("runtime.data.providers.selfhost must be self-managed-postgresql")
    if data.get("providers", {}).get("serverless") != "supabase":
        fail("runtime.data.providers.serverless must be supabase")
    # GitOps declares the runtime topology and its migration capabilities; it
    # does not authorize or select a control-plane operation for this run.
    # The latter is selected by platform-ops-toolkit's explicit operation
    # routing and must not be inferred from this declaration.
    if not isinstance(migration.get("enabled"), bool):
        fail("runtime.data.migration.enabled must be an explicit boolean")
    if migration.get("strategy") != "async" or migration.get("single_writer") is not True:
        fail("runtime.data.migration must reserve async single-writer handover")
    if migration.get("max_lag_seconds") != 60 or migration.get("require_quiesce_for_cutover") is not True:
        fail("runtime.data.migration must retain the 60-second lag and quiesce requirements")

    env_suffix = "" if expected_environment == "prod" else f"-{expected_environment}"
    expected_host_zone = expected_environment_zone
    canonical_records = dns.get("canonical_records", {})
    expected_records = {
        f"console{env_suffix}.{expected_host_zone}": f"console-vps-{expected_environment}.{expected_host_zone}",
        f"accounts{env_suffix}.{expected_host_zone}": f"accounts-vps-{expected_environment}.{expected_host_zone}",
    }
    if canonical_records != expected_records:
        fail(
            f"canonical_records must select the declared {expected_environment} "
            "selfhost VPS targets"
        )

    domains = spec.get("domains", {})
    for canonical, target in expected_records.items():
        if domains.get(canonical, {}).get("selfhost") != target:
            fail(f"domains.{canonical}.selfhost must match canonical_records")

    vps = spec.get("vps", {})
    if vps.get("stack") != "full-stack" or vps.get("database") != "self-managed-postgresql":
        fail("spec.vps must declare full-stack with self-managed-postgresql")
    if vps.get("services") != ["console", "accounts", "content", "billing"]:
        fail("spec.vps.services must declare the four web-saas services")

    migration_state = "enabled" if migration.get("enabled") else "disabled"
    print(
        "GitOps selfhost contract valid: "
        f"{expected_environment} -> VPS Full Stack, DNS-only, selfhost=100, "
        f"PostgreSQL primary, migration {migration_state}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
