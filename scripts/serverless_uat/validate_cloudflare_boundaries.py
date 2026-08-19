#!/usr/bin/env python3
"""Validate the declarative Cloudflare edge boundary contract."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def validate_data_topology(data: dict[str, object]) -> None:
    """Validate declarative data topology without selecting an operation."""
    providers = data.get("providers", {})
    if not isinstance(providers, dict):
        raise SystemExit("GitOps runtime data must define database providers")
    if providers.get("selfhost") != "self-managed-postgresql":
        raise SystemExit("GitOps selfhost database mode must use self-managed-postgresql")
    if providers.get("serverless") != "supabase":
        raise SystemExit("GitOps Serverless database mode must use Supabase")
    if data.get("primary") not in {"selfhost", "serverless"} or data.get("replica") not in {"selfhost", "serverless"}:
        raise SystemExit("GitOps runtime data must define selfhost or serverless primary and replica modes")
    migration = data.get("migration", {})
    if not isinstance(migration, dict):
        raise SystemExit("GitOps runtime data must define a migration topology")
    if migration.get("strategy") != "async" or migration.get("single_writer") is not True:
        raise SystemExit("GitOps runtime migration must reserve async DTS with single_writer=true")


def main() -> int:
    configured_path = os.environ.get("CLOUDFLARE_BOUNDARY_CONFIG")
    if not configured_path:
        raise SystemExit("CLOUDFLARE_BOUNDARY_CONFIG must point to the GitOps routing manifest")
    manifest_path = Path(configured_path)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("kind") != "EdgeRoutingConfig":
        raise SystemExit("GitOps routing manifest must be an EdgeRoutingConfig")
    metadata = manifest.get("metadata", {})
    spec = manifest.get("spec", {})
    runtime = spec.get("runtime", {})
    mode = runtime.get("mode")
    if mode not in {"serverless", "hybrid"}:
        raise SystemExit("Cloudflare boundary deployment requires runtime.mode=serverless or hybrid")
    if metadata.get("mode") != mode:
        raise SystemExit("GitOps routing metadata.mode must match spec.runtime.mode")
    required_mode = os.environ.get("REQUIRED_RUNTIME_MODE")
    if required_mode and mode != required_mode:
        raise SystemExit(f"GitOps routing manifest requires runtime.mode={required_mode}, got {mode}")
    if set(runtime.get("routing", {})) != {"dns", "load-balancer", "weight"}:
        raise SystemExit("GitOps runtime routing must define dns, load-balancer, and weight")
    if set(runtime.get("services", {})) != {"console", "accounts", "content", "billing"}:
        raise SystemExit("GitOps runtime services must define console, accounts, content, and billing")

    domains = spec.get("domains", {})
    environment = manifest.get("metadata", {}).get("environment", "")
    mode_suffix = "svc.plus" if environment == "prod" else "onwalk.net"
    public_endpoints = spec.get("public_endpoints", {})
    expected_access = {
        "console": "public",
        "accounts": "authenticated",
        "billing": "authenticated",
        "postgresql": "authenticated",
        "agent-proxy": "public_uuid",
    }
    if set(public_endpoints) != set(expected_access):
        raise SystemExit("GitOps public_endpoints must define exactly console, accounts, billing, postgresql, and agent-proxy")
    for service, access in expected_access.items():
        endpoint = public_endpoints[service]
        expected_host = f"{service}-{mode}-{environment}.{mode_suffix}"
        if endpoint.get("host") != expected_host:
            raise SystemExit(f"public_endpoints.{service}.host must be {expected_host!r}")
        if endpoint.get("access") != access:
            raise SystemExit(f"public_endpoints.{service}.access must be {access!r}")
    required_domains = (
        {"console.svc.plus", "accounts.svc.plus"}
        if environment == "prod"
        else {f"console-{environment}.onwalk.net", f"accounts-{environment}.onwalk.net"}
    )
    if not required_domains.issubset(domains):
        raise SystemExit("GitOps routing manifest must define canonical console and accounts domains")
    for canonical in required_domains:
        record = domains[canonical]
        if not record.get("selfhost") or not record.get("serverless"):
            raise SystemExit(f"domain {canonical} must define selfhost and serverless CNAME targets")

    serverless = spec.get("serverless", {})
    if len(serverless.get("ssr", [])) != 5:
        raise SystemExit("GitOps routing manifest must define exactly five SSR boundaries")
    if len(serverless.get("edge_gateway", {}).get("boundaries", [])) != 3:
        raise SystemExit("GitOps routing manifest must define exactly three edge-gateway boundaries")
    frontend_router = serverless.get("frontend_router")
    if mode == "serverless":
        if not isinstance(frontend_router, dict):
            raise SystemExit("GitOps serverless topology must define frontend_router")
        required_router_fields = {"worker_name", "host", "pages_origin", "api_origin", "static_prefixes", "bindings"}
        missing_router_fields = required_router_fields - set(frontend_router)
        if missing_router_fields:
            raise SystemExit(
                "GitOps frontend_router is missing: " + ", ".join(sorted(missing_router_fields))
            )
        if not isinstance(frontend_router.get("static_prefixes"), list) or not {
            "/_next/*", "/static/*", "/assets/*"
        }.issubset(frontend_router["static_prefixes"]):
            raise SystemExit("GitOps frontend_router must define standard static prefixes")
        bindings = frontend_router.get("bindings")
        expected_binding_ids = {"auth", "content", "console", "workspace", "public"}
        if not isinstance(bindings, dict) or set(bindings) != expected_binding_ids:
            raise SystemExit("GitOps frontend_router must define exactly five SSR bindings")
    data = runtime.get("data", {})
    if not isinstance(data, dict):
        raise SystemExit("GitOps runtime must define a data topology")
    validate_data_topology(data)
    hosts = {
        "console": serverless.get("console_host", ""),
        "accounts": serverless.get("accounts_host", ""),
    }
    canonical_console = "console.svc.plus" if environment == "prod" else f"console-{environment}.onwalk.net"
    canonical_accounts = "accounts.svc.plus" if environment == "prod" else f"accounts-{environment}.onwalk.net"
    if hosts["console"] != domains[canonical_console]["serverless"]:
        raise SystemExit("Serverless console host must match the canonical domain serverless target")
    if hosts["accounts"] != domains[canonical_accounts]["serverless"]:
        raise SystemExit("Serverless accounts host must match the canonical domain serverless target")
    if serverless.get("billing_host") != f"billing-serverless-{environment}.{mode_suffix}":
        raise SystemExit("Serverless billing host must use the billing-serverless-<environment> naming contract")
    if mode == "serverless":
        billing_origin_host = serverless.get("billing_origin_host", "")
        expected_billing_origin = f"billing-origin-serverless-{environment}.{mode_suffix}"
        if billing_origin_host and billing_origin_host != expected_billing_origin:
            raise SystemExit(
                "Legacy serverless billing_origin_host must use the billing-origin-serverless-<environment> naming contract"
            )
        if billing_origin_host and billing_origin_host == serverless.get("billing_host"):
            raise SystemExit("Serverless billing_origin_host must be separate from billing_host")
    boundaries = []
    if mode == "serverless":
        assert isinstance(frontend_router, dict)
        if frontend_router["host"] != hosts["console"]:
            raise SystemExit("frontend_router.host must match the serverless console host")
        if frontend_router["api_origin"] != f"https://{hosts['accounts']}":
            raise SystemExit("frontend_router.api_origin must use the serverless accounts host")
        if frontend_router["pages_origin"] != f"https://{spec.get('cloudflare', {}).get('pages_project', '')}.pages.dev":
            raise SystemExit("frontend_router.pages_origin must use the declared Pages project origin")
        boundaries.append({
            "id": "frontend-router",
            "kind": "worker",
            "name": frontend_router["worker_name"],
            "host": "console",
            "routes": ["/*"],
        })
    for item in serverless.get("ssr", []):
        boundaries.append({
            "id": f"ssr-{item['id']}",
            "kind": "worker",
            "name": item["worker_name"],
            "host": "console",
            "routes": item["route_suffixes"],
        })
    for item in serverless.get("edge_gateway", {}).get("boundaries", []):
        routes = item.get("routes")
        if not isinstance(routes, list):
            legacy_route = item.get("route")
            if mode == "hybrid" and isinstance(legacy_route, str):
                routes = [legacy_route]
            else:
                raise SystemExit(f"api-{item.get('id', '')} must define a routes array")
        boundaries.append({
            "id": f"api-{item['id']}",
            "kind": "worker",
            "name": item["worker_name"],
            "host": "accounts",
            "routes": routes,
        })
    boundaries.append({
        "id": "static",
        "kind": "pages",
        "name": spec.get("cloudflare", {}).get("pages_project", ""),
        "host": "console",
        "routes": ["/static/*", "/assets/*"],
    })
    if not boundaries:
        raise SystemExit("Cloudflare boundary manifest must define at least one boundary")
    if not hosts.get("console") or not hosts.get("accounts"):
        raise SystemExit("Cloudflare boundary manifest must define console and accounts Cloudflare hosts")

    ids: set[str] = set()
    names: set[str] = set()
    for boundary in boundaries:
        boundary_id = boundary.get("id", "")
        name = boundary.get("name", "")
        routes = boundary.get("routes", [])
        host = boundary.get("host", "")
        if not boundary_id or boundary_id in ids:
            raise SystemExit(f"duplicate or empty Cloudflare boundary id: {boundary_id!r}")
        if not name or name in names:
            raise SystemExit(f"duplicate or empty Cloudflare Worker/Pages name: {name!r}")
        if not routes or any(not route.startswith("/") for route in routes):
            raise SystemExit(f"invalid route boundary for {boundary_id}: {routes!r}")
        if host not in hosts:
            raise SystemExit(f"invalid host boundary for {boundary_id}: {host!r}")
        ids.add(boundary_id)
        names.add(name)

    boundary_by_id = {boundary["id"]: boundary for boundary in boundaries}
    required_routes = {
        "ssr-public": ("frontend-ssr-public-" + environment, {"/*", "/_edge/public/*"}),
        "ssr-content": ("frontend-ssr-content-" + environment, {"/blogs*", "/docs*", "/download*", "/_edge/content/*"}),
        "ssr-auth": ("frontend-ssr-auth-" + environment, {"/login*", "/register*", "/email-verification*", "/logout*", "/_edge/auth/*"}),
        "ssr-console": ("frontend-ssr-console-" + environment, {"/panel*", "/dashboard*", "/_edge/console/*"}),
        "ssr-workspace": ("frontend-ssr-workspace-" + environment, {"/ai-workspace*", "/cloud_iac*", "/editor*", "/support*", "/xworkmate*", "/_edge/workspace/*"}),
        "api-auth": ("edge-gateway-auth-" + environment, {"/api/auth/*", "/api/v1/auth/*"}),
        "api-admin": ("edge-gateway-admin-" + environment, {"/api/admin/*"}),
        "api-core": ("edge-gateway-core-" + environment, {"/api/*"}),
        "static": (spec.get("cloudflare", {}).get("pages_project", ""), {"/static/*", "/assets/*"}),
    }
    if mode == "serverless":
        required_routes["frontend-router"] = ("frontend-router-" + environment, {"/*"})
    for boundary_id, (expected_name, expected_routes) in required_routes.items():
        boundary = boundary_by_id[boundary_id]
        if boundary["name"] != expected_name:
            raise SystemExit(f"{boundary_id} must use worker/project name {expected_name!r}")
        missing_routes = expected_routes - set(boundary["routes"])
        if missing_routes:
            raise SystemExit(f"{boundary_id} is missing routes: {', '.join(sorted(missing_routes))}")

    required = {"ssr-public", "ssr-content", "ssr-auth", "ssr-console", "ssr-workspace", "api-auth", "api-admin", "api-core", "static"}
    if mode == "serverless":
        required.add("frontend-router")
    missing = required - ids
    if missing:
        raise SystemExit(f"Cloudflare boundary contract is missing: {', '.join(sorted(missing))}")
    if "/api/*" not in next(boundary["routes"] for boundary in boundaries if boundary["id"] == "api-core"):
        raise SystemExit("api-core must retain the catch-all /api/* boundary")
    core_topology = next(
        item for item in serverless.get("edge_gateway", {}).get("boundaries", [])
        if item.get("id") == "core"
    )
    if mode == "serverless" and core_topology.get("display_name") != "Edge Gateway Router Core":
        raise SystemExit("GitOps api-core display_name must be Edge Gateway Router Core")
    for boundary_id in ("api-auth", "api-admin", "api-core"):
        boundary = next(boundary for boundary in boundaries if boundary["id"] == boundary_id)
        if boundary["host"] != "accounts":
            raise SystemExit(f"{boundary_id} must use the accounts Cloudflare host")

    print(f"Cloudflare boundary contract valid: {len(boundaries)} boundaries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
