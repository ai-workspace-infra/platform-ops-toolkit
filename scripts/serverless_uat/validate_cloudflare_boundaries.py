#!/usr/bin/env python3
"""Validate the declarative Cloudflare edge boundary contract."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    manifest_path = Path(__file__).resolve().parents[2] / ".github/serverless/cloudflare-boundaries.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    boundaries = manifest.get("boundaries", [])
    hosts = manifest.get("hosts", {})
    if not boundaries:
        raise SystemExit("Cloudflare boundary manifest must define at least one boundary")
    if hosts.get("console") != "console-cloudflare-uat.onwalk.net":
        raise SystemExit("Cloudflare boundary manifest must define the console Cloudflare host")
    if hosts.get("accounts") != "accounts-cloudflare-uat.onwalk.net":
        raise SystemExit("Cloudflare boundary manifest must define the accounts Cloudflare host")

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

    required = {"ssr-public", "ssr-content", "ssr-auth", "ssr-console", "ssr-workspace", "api-auth", "api-admin", "api-core", "static"}
    missing = required - ids
    if missing:
        raise SystemExit(f"Cloudflare boundary contract is missing: {', '.join(sorted(missing))}")
    if "/api/*" not in next(boundary["routes"] for boundary in boundaries if boundary["id"] == "api-core"):
        raise SystemExit("api-core must retain the catch-all /api/* boundary")
    for boundary_id in ("api-auth", "api-admin", "api-core"):
        boundary = next(boundary for boundary in boundaries if boundary["id"] == boundary_id)
        if boundary["host"] != "accounts":
            raise SystemExit(f"{boundary_id} must use the accounts Cloudflare host")

    print(f"Cloudflare boundary contract valid: {len(boundaries)} boundaries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
