#!/usr/bin/env python3
"""Validate a non-secret XConnect network declaration and build a private request."""

from __future__ import annotations

import ipaddress
import json
import os
import re
import sys
import uuid
from pathlib import Path
from urllib.parse import urlparse

import yaml


def fail(message: str) -> "None":
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def required_string(value: object, label: str, pattern: str | None = None) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"GitOps declaration requires {label}")
    value = value.strip()
    if any(ord(char) < 32 for char in value):
        fail(f"GitOps declaration has control characters in {label}")
    if pattern and not re.fullmatch(pattern, value):
        fail(f"GitOps declaration has invalid {label}")
    return value


def main() -> None:
    target_environment = os.environ.get("NETWORK_ENVIRONMENT", "")
    if target_environment not in {"prod", "custom"}:
        fail("network_environment must be prod or custom")
    manifest = Path(os.environ.get("NETWORK_MANIFEST", ""))
    if manifest.is_absolute() or ".." in manifest.parts or not str(manifest).startswith("gitops/vpn-overlay/networks/"):
        fail("network_manifest must resolve below the checked-out GitOps vpn-overlay/networks directory")
    try:
        manifest_real = manifest.resolve(strict=True)
        networks_root = Path("gitops/vpn-overlay/networks").resolve(strict=True)
        manifest_real.relative_to(networks_root)
    except (OSError, ValueError):
        fail("GitOps network declaration must be a regular file contained by vpn-overlay/networks")
    if manifest.suffix not in {".yaml", ".yml"} or not manifest_real.is_file():
        fail("GitOps network declaration does not exist or is not YAML")

    try:
        document = yaml.safe_load(manifest.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        fail(f"Could not parse GitOps network declaration: {type(exc).__name__}")
    if not isinstance(document, dict):
        fail("GitOps network declaration must be a YAML object")
    if document.get("apiVersion") != "gitops.svc.plus/v1alpha1" or document.get("kind") != "XConnectNetwork":
        fail("GitOps declaration must use apiVersion gitops.svc.plus/v1alpha1 and kind XConnectNetwork")
    metadata = document.get("metadata") or {}
    spec = document.get("spec") or {}
    if not isinstance(metadata, dict) or not isinstance(spec, dict):
        fail("GitOps metadata and spec must be objects")
    if metadata.get("environment") != target_environment:
        fail("Selected target scope does not match metadata.environment in GitOps")

    zero = spec.get("zero") or {}
    network = spec.get("network") or {}
    gateway = spec.get("gateway") or {}
    transport = gateway.get("transport") or {}
    if not all(isinstance(value, dict) for value in (zero, network, gateway, transport)):
        fail("GitOps zero/network/gateway/transport declarations must be objects")
    accounts_url = required_string(zero.get("accounts_api_url"), "spec.zero.accounts_api_url")
    parsed_url = urlparse(accounts_url)
    if parsed_url.scheme != "https" or not parsed_url.hostname or parsed_url.username or parsed_url.password or parsed_url.query or parsed_url.fragment:
        fail("spec.zero.accounts_api_url must be an HTTPS origin/base URL without credentials, query, or fragment")
    hostname = parsed_url.hostname.lower().rstrip(".")
    if not (hostname == "svc.plus" or hostname.endswith(".svc.plus") or hostname == "onwalk.net" or hostname.endswith(".onwalk.net")):
        fail("spec.zero.accounts_api_url host must belong to an approved svc.plus or onwalk.net service domain")

    network_id = required_string(network.get("id"), "spec.network.id", r"net_[a-zA-Z0-9][a-zA-Z0-9_-]{1,62}")
    display_name = required_string(network.get("display_name"), "spec.network.display_name")
    cidr = required_string(network.get("cidr"), "spec.network.cidr")
    try:
        overlay = ipaddress.ip_network(cidr, strict=True)
        gateway_address = ipaddress.ip_interface(required_string(gateway.get("wireguard_address"), "spec.gateway.wireguard_address"))
    except ValueError:
        fail("GitOps network CIDR or Gateway WireGuard address is invalid")
    if overlay.version != 4 or gateway_address.version != 4 or gateway_address.ip not in overlay:
        fail("GitOps network and Gateway address must be IPv4 and the Gateway must belong to the network CIDR")
    gateway_id = required_string(gateway.get("id"), "spec.gateway.id", r"gw-[a-zA-Z0-9][a-zA-Z0-9_-]{1,62}")
    gateway_public_key = required_string(gateway.get("wireguard_public_key"), "spec.gateway.wireguard_public_key", r"[A-Za-z0-9+/]{43}=")
    endpoint_host = required_string(gateway.get("endpoint_host"), "spec.gateway.endpoint_host", r"[A-Za-z0-9.-]+")
    server_name = required_string(transport.get("server_name"), "spec.gateway.transport.server_name", r"[A-Za-z0-9.-]+")
    transport_kind = required_string(transport.get("kind"), "spec.gateway.transport.kind", r"[a-z0-9-]+")
    transport_path = required_string(transport.get("path"), "spec.gateway.transport.path", r"/[A-Za-z0-9/_-]*")
    transport_mode = required_string(transport.get("mode"), "spec.gateway.transport.mode", r"[a-z0-9-]+")
    transport_host = required_string(transport.get("host", server_name), "spec.gateway.transport.host", r"[A-Za-z0-9.-]+")
    transport_port = transport.get("port")
    endpoint_port = gateway.get("endpoint_port", 51820)
    if not isinstance(transport_port, int) or not 1 <= transport_port <= 65535:
        fail("spec.gateway.transport.port must be an integer TCP port")
    if not isinstance(endpoint_port, int) or not 1 <= endpoint_port <= 65535:
        fail("spec.gateway.endpoint_port must be an integer port")
    device_id = required_string(gateway.get("device_id", f"gateway-{network_id.removeprefix('net_')}"), "spec.gateway.device_id", r"[a-z0-9][a-z0-9._-]{0,127}")
    expires_minutes = spec.get("invitation_ttl_minutes", 15)
    if not isinstance(expires_minutes, int) or not 5 <= expires_minutes <= 30:
        fail("spec.invitation_ttl_minutes must be between 5 and 30")

    owner = required_string(zero.get("owner_email"), "spec.zero.owner_email", r"[^\s@]+@[^\s@]+\.[^\s@]+")
    vless_id = required_string(os.environ.get("VLESS_ID"), "Vault VLESS_ID")
    try:
        uuid.UUID(vless_id)
    except ValueError:
        fail("Vault VLESS_ID must be a UUID")
    output_path = Path(os.environ["REQUEST_FILE"])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    request = {
        "owner_email": owner,
        "bootstrap": {
            "controller_url": accounts_url,
            "network": {
                "id": network_id,
                "display_name": display_name,
                "cidr": str(overlay),
                "gateway_id": gateway_id,
                "gateway_wireguard_public_key": gateway_public_key,
                "gateway_wireguard_address": str(gateway_address),
                "gateway_endpoint_host": endpoint_host,
                "gateway_endpoint_port": endpoint_port,
                "transport_server_name": server_name,
                "transport_port": transport_port,
                "transport_auth_id": vless_id,
                "transport_kind": transport_kind,
                "transport_path": transport_path,
                "transport_mode": transport_mode,
                "transport_host": transport_host,
            },
            "invite": {
                "device_id": device_id,
                "platform": "linux",
                "role": "gateway",
                "expires_at": "__GENERATE_AT_RUNTIME__",
                "ttl_minutes": expires_minutes,
            },
        },
    }
    output_path.write_text(json.dumps(request, separators=(",", ":")), encoding="utf-8")
    output_path.chmod(0o600)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"network_id={network_id}\n")
        output.write(f"accounts_api_url={accounts_url}\n")
        output.write(f"gateway_id={gateway_id}\n")
        output.write(f"invitation_ttl_minutes={expires_minutes}\n")
    print(f"Validated GitOps network declaration: scope={target_environment}, network_id={network_id}; secrets omitted")


if __name__ == "__main__":
    main()
