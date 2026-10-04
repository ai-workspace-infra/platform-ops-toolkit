#!/usr/bin/env python3
"""Synchronous, correlated dispatch to the single data control plane (no DB logic)."""
import json
import os
import re
import subprocess
import time
import uuid

WORKFLOW = "environment-data-operations.yml"
REPOSITORY = "ai-workspace-infra/platform-ops-toolkit"


def gh(*arguments, payload=None):
    result = subprocess.run(["gh", *arguments], input=json.dumps(payload) if payload else None,
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout) if result.stdout.strip() else {}


def main():
    ref = os.environ.get("DATA_WORKFLOW_REF", "main")
    if not re.fullmatch(r"main|[0-9a-f]{40}|(?:uat-)?daily-build-[0-9.]+(?:-r[1-9][0-9]*)?|v[0-9.]+(?:-r[1-9][0-9]*)?", ref):
        raise SystemExit("Data entry requires main or an immutable reviewed ref")
    correlation = "data-" + uuid.uuid4().hex
    inputs = {
        "environment": os.environ["DATA_ENVIRONMENT"],
        "mode": os.environ["DATA_OPERATION"],
        "config_json": os.environ.get("DATA_CONFIG_JSON", "{}"),
        "correlation_id": correlation,
        "release_tag": os.environ.get("RELEASE_TAG", ""),
        "accounts_ref": os.environ.get("ACCOUNTS_REF", "main"),
    }
    for field in ("candidate_run_id", "expected_schema_version", "target_schema_version", "migration_sha256"):
        if os.environ.get(field.upper()):
            inputs[field] = os.environ[field.upper()]
    # Validate JSON before dispatch; never echo its potentially private contents.
    config = json.loads(inputs["config_json"])
    if not isinstance(config, dict):
        raise SystemExit("Data configuration must be an object")
    for field in ("candidate_run_id", "expected_schema_version", "target_schema_version", "migration_sha256"):
        if field not in inputs and config.get(field):
            inputs[field] = str(config[field])
    created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    gh("api", "--method", "POST", f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/dispatches",
       "--input", "-", payload={"ref": ref, "inputs": inputs})
    deadline = time.monotonic() + int(os.environ.get("DATA_WAIT_SECONDS", "7200"))
    run = None
    while time.monotonic() < deadline:
        if run is None:
            listing = gh("api", f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100&created=%3E%3D{created}")
            matches = [item for item in listing["workflow_runs"]
                       if item.get("display_title", "").startswith(f"data:{correlation} /")]
            if len(matches) > 1:
                raise SystemExit("Ambiguous child execution; refusing to guess")
            if matches:
                run = matches[0]
                print("Data operation:", run["html_url"], flush=True)
        else:
            run = gh("api", f"repos/{REPOSITORY}/actions/runs/{run['id']}")
        if run and run["status"] == "completed":
            if run["conclusion"] != "success":
                raise SystemExit(f"Data operation failed: {run['html_url']} ({run['conclusion']})")
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                    output.write(f"data_run_id={run['id']}\ndata_run_url={run['html_url']}\n")
            return
        time.sleep(10)
    raise SystemExit("Child timeout (not acceptance); inspect correlated run before retrying")


if __name__ == "__main__":
    main()
