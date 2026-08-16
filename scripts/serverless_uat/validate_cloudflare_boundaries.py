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
    if not boundaries:
        raise SystemExit("Cloudflare boundary manifest must define at least one boundary")

    ids: set[str] = set()
    names: set[str] = set()
    for boundary in boundaries:
        boundary_id = boundary.get("id", "")
        name = boundary.get("name", "")
        routes = boundary.get("routes", [])
        if not boundary_id or boundary_id in ids:
            raise SystemExit(f"duplicate or empty Cloudflare boundary id: {boundary_id!r}")
        if not name or name in names:
            raise SystemExit(f"duplicate or empty Cloudflare Worker/Pages name: {name!r}")
        if not routes or any(not route.startswith("/") for route in routes):
            raise SystemExit(f"invalid route boundary for {boundary_id}: {routes!r}")
        ids.add(boundary_id)
        names.add(name)

    api_routes = [
        route
        for boundary in boundaries
        if boundary.get("kind") == "worker" and boundary.get("id", "").startswith("api-")
        for route in boundary.get("routes", [])
    ]
    if "/api/*" not in api_routes:
        raise SystemExit("api-core must retain the catch-all /api/* boundary")
    if "/api/auth/*" not in api_routes or "/api/admin/*" not in api_routes:
        raise SystemExit("api-auth and api-admin must define their explicit route boundaries")

    print(f"Cloudflare boundary contract valid: {len(boundaries)} boundaries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
