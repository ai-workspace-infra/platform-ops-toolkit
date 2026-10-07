#!/usr/bin/env python3
"""Dispatch the fixed PROD Selfhost copy and publish a core-user-only receipt.

This is a control-plane adapter. It never connects to either database and it
never republishes table rows, password hashes, or Proxy UUID values.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

REPOSITORY = "ai-workspace-infra/platform-ops-toolkit"
WORKFLOW = "selfhost-orchestrator.yml"
RECEIPT_NAME = "prod-full-business-receipt"
TAG = re.compile(r"v[0-9]+(?:\.[0-9]+)+(?:-r[1-9][0-9]*)?")
HEX = re.compile(r"[0-9a-f]{64}")


def gh(*args, payload=None):
    env = os.environ.copy()
    result = subprocess.run(["gh", *args], input=json.dumps(payload) if payload is not None else None,
                            text=True, capture_output=True, check=True, env=env, timeout=60)
    return json.loads(result.stdout) if result.stdout.strip() else {}


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def validate_core_receipt(receipt, run, compare=False):
    require(receipt.get("environment") == "prod", "core receipt environment differs")
    require(receipt.get("scope") == "core_users" and receipt.get("stage") == ("core_users_compared" if compare else "core_users_copied"),
            "core receipt scope differs")
    require(receipt.get("host") == "web-saas-prod" and receipt.get("database") == "account",
            "core receipt target differs")
    require(receipt.get("source_read_only") is True and receipt.get("target_writes") is (not compare),
            "core receipt does not prove read-only source and writable target")
    core = receipt.get("core_users")
    require(isinstance(core, dict) and set(core) == {"source", "target"},
            "core-user evidence is missing")
    for side in ("source", "target"):
        proof = core[side]
        require(isinstance(proof, dict) and set(proof) == {
            "count", "email_sha256", "password_hash_sha256", "email_proxy_sha256"},
            "core-user evidence shape differs")
        require(type(proof["count"]) is int and proof["count"] > 0 and
                all(HEX.fullmatch(proof[key] or "") for key in (
                    "email_sha256", "password_hash_sha256", "email_proxy_sha256")),
                "core-user evidence digest is invalid")
    require(core["source"] == core["target"],
            "source and target core-user identity sets differ")
    require(receipt.get("user_count") == core["source"]["count"],
            "core-user count differs from source user count")
    require(receipt.get("tables") == {}, "core receipt must not claim dynamic table equality")
    require(run.get("status") == "completed" and run.get("conclusion") == "success",
            "Selfhost child did not complete successfully")
    # The owner receipt may contain table-level counts/digests. It is consumed
    # privately here; the EDO artifact below deliberately omits that evidence
    # and never republishes user rows or identity values.
    return core


def dispatch_inputs(tag, action="compare"):
    require(action in ("copy", "compare", "availability"), "unsupported Selfhost action")
    return {
        "runner_type": "ubuntu-latest",
        # Native core-user transfer does not deploy application images; the
        # workflow ref above is the sole release selector.
        "deploy_tag": "",
        # The workflow ref is the immutable release tag. Native owner
        # validation accepts only an empty source override or the resolved
        # commit SHA, so do not duplicate the tag in source_ref.
        "source_ref": "",
        "offline_mode": "off",
        "source_host": "install.svc.plus",
        "source_domain_base": "svc.plus",
        "target_domain_base": "svc.plus",
        "observability_endpoint": "https://observability.svc.plus",
        "xray_exporter_image": "",
        "operation": {"copy": "native-core-users", "compare": "native-core-users-compare", "availability": "native-availability"}[action],
        "target_domains": "web-saas",
        "open_platform_service": "all",
        "cloud_provider": "gcp-cloud",
        "cloud_account": "xworktech",
        "akamai_account": "",
        "include_external_agent_proxy": "false",
        "instance_plan": "2C4G",
        "agent_proxy_plan": "1C2G",
        "dns_mode": "none",
        "vault_env_path": "prod",
        "skip_stripe_catalog": "true",
        "agent_controller_url": "",
        "vault_addr": "https://vault.svc.plus",
        "xconnect_gateway_ref": "tw-xconnect.svc.plus",
        "existing_target_host": "",
    }


def main():
    tag = os.environ.get("RELEASE_TAG", "")
    require(TAG.fullmatch(tag), "core_users requires an immutable PROD release tag")
    config = json.loads(os.environ.get("DATA_CONFIG_JSON", "{}"))
    require(config.get("execution_path", "selfhost_core_users") == "selfhost_core_users",
            "unexpected core_users execution path")
    require(config.get("source_read_only") is True or config.get("action") == "availability", "source_read_only contract is required")
    created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    action = config.get("action", "compare")
    payload = {"ref": tag, "inputs": dispatch_inputs(tag, action)}
    gh("api", "--method", "POST", f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/dispatches",
       "--input", "-", payload=payload)
    deadline = time.monotonic() + int(os.environ.get("DATA_WAIT_SECONDS", "7200"))
    child = None
    while time.monotonic() < deadline:
        listing = gh("api", f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100&created=%3E%3D{created}")
        matches = [item for item in listing.get("workflow_runs", [])
                   if item.get("head_branch") == tag and item.get("event") == "workflow_dispatch" and
                   item.get("path", "").split("@", 1)[0] == ".github/workflows/selfhost-orchestrator.yml" and
                   item.get("repository", {}).get("full_name") == REPOSITORY]
        require(len(matches) <= 1, "ambiguous Selfhost child execution; refusing to guess")
        if matches:
            child = matches[0]
            if child.get("status") == "completed":
                break
        time.sleep(10)
    require(child is not None, "Selfhost child was not resolved")
    require(child.get("status") == "completed" and child.get("conclusion") == "success",
            "Selfhost core-user copy did not succeed")
    temp = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "core-user-sync"
    temp.mkdir(mode=0o700, parents=True, exist_ok=True)
    archive = temp / "owner-receipt"
    archive.mkdir(mode=0o700, exist_ok=True)
    gh("run", "download", str(child["id"]), "--repo", REPOSITORY, "--name", "prod-availability-receipt" if action == "availability" else RECEIPT_NAME,
       "--dir", str(archive))
    source = archive / ("prod-availability-receipt.json" if action == "availability" else "prod-full-business-receipt.json")
    require(source.is_file() and source.stat().st_size <= 65536, "missing or oversized owner receipt")
    receipt = json.loads(source.read_text())
    if action == "availability":
        require(receipt.get('environment') == 'prod' and receipt.get('host') == 'web-saas-prod' and
            receipt.get('result') == 'available' and receipt.get('target_writes') is False and
            receipt.get('database_cutover_approved') is False and all(receipt.get(k) is True for k in
            ('doco_synced','containers_healthy','caddy_running','https_available','api_available','db_available')),
            'Selfhost availability evidence is incomplete')
        public = {**receipt, 'run_id': child['id'], 'workflow_sha': child['head_sha'], 'release_tag': tag}
        (temp / 'core-user-sync-receipt.json').write_text(json.dumps(public, sort_keys=True) + '\n')
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write(f"child_run_id={child['id']}\n")
        print('Availability accepted; no data writes or DNS change')
        return
    core = validate_core_receipt(receipt, child, compare=action == "compare")
    public = {
        "schema": "edge-gateway-cutover/v2",
        "evidence": "core-user-sync",
        "environment": "prod",
        "run_id": child["id"],
        "workflow_sha": child.get("head_sha"),
        "release_tag": tag,
        "verified_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source_read_only": True,
        "writers_quiesced": False,
        "single_writer": False,
        "latest_native_schema": receipt.get("migration_version") == 2026100701,
        "database_cutover_approved": False,
        "core_users": core,
    }
    out = temp / "core-user-sync-receipt.json"
    out.write_text(json.dumps(public, sort_keys=True) + "\n")
    out.chmod(0o600)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"child_run_id={child['id']}\nchild_run_url={child.get('html_url', '')}\n")
    print(f"Core-user evidence accepted for child run {child['id']}; cutover remains gated", flush=True)


if __name__ == "__main__":
    main()
