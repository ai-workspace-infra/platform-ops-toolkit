#!/usr/bin/env python3
"""Validate the cross-repository Resend DNS contract without network access."""
import argparse
from pathlib import Path
import yaml


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gitops", required=True, type=Path)
    parser.add_argument("--playbook", required=True, type=Path)
    args = parser.parse_args()
    policy = yaml.safe_load(args.gitops.read_text())
    playbook = args.playbook.read_text()
    spec = policy["spec"]
    expected = {"no-reply@xworktech.com", "support@xworktech.com", "billing@xworktech.com", "security@xworktech.com"}
    assert set(spec["resend"]["from_addresses"]) == expected
    assert spec["resend"]["spf_include"] and spec["google_workspace"]["spf_include"]
    assert len(spec["google_workspace"]["mx"]) == 5
    assert spec["dmarc"]["name"] == "_dmarc.xworktech.com"
    assert "EMAIL_DNS_APPLY" in playbook and "default('false'" in playbook
    assert "EMAIL_DNS_CONFIG_PATH" in playbook
    print("Resend DNS cross-repository contract: PASS")


if __name__ == "__main__":
    main()
