#!/usr/bin/env python3
"""Read-only public TLS gate before opening an agent-reported UAT region."""
import argparse
import json
import re
import socket
import ssl
import urllib.request
from pathlib import Path


def verify(host):
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?-xconnect\.onwalk\.net", host):
        raise ValueError("Entry must be a UAT regional xconnect hostname in onwalk.net")
    result = {"entry_point": host, "environment": "uat", "tls": {}}
    context = ssl.create_default_context()
    for port in (443, 1443):
        with socket.create_connection((host, port), timeout=15) as raw:
            with context.wrap_socket(raw, server_hostname=host) as conn:
                result["tls"][str(port)] = conn.version()
    with urllib.request.urlopen(f"https://{host}/", timeout=15, context=context) as response:
        result["https_status"] = response.status
        if response.status != 200:
            raise ValueError("Regional HTTPS listener is not ready")
    result["public_listener_ready"] = True
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entry", required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = verify(args.entry)
    except Exception as error:
        report = {"entry_point": args.entry, "environment": "uat", "public_listener_ready": False, "failure": type(error).__name__}
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        raise SystemExit("UAT public listener acceptance failed: " + type(error).__name__)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
