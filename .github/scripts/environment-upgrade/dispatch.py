#!/usr/bin/env python3
"""Synchronous, correlated dispatch to the single data control plane (no DB logic)."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid
from validate_operation import validate_config

WORKFLOW = "environment-data-operations.yml"
REPOSITORY = "ai-workspace-infra/platform-ops-toolkit"


def gh(*arguments, payload=None, timeout=30):
    environment = os.environ.copy()
    if payload is None and environment.get("RUN_STATUS_TOKEN"):
        environment["GH_TOKEN"] = environment["RUN_STATUS_TOKEN"]
    result = subprocess.run(["gh", *arguments], input=json.dumps(payload) if payload else None,
                            text=True, capture_output=True, check=True, env=environment, timeout=timeout)
    return json.loads(result.stdout) if result.stdout.strip() else {}


def stop_child(state, reason):
    """Cancel only the exact correlated child; cancellation is not DB rollback proof."""
    run = state.get('run')
    if run is None:
        # A dispatch POST can succeed even when the client sees a timeout. Resolve
        # the child by this invocation's correlation id before deciding that no
        # child exists; never cancel a workflow selected only by recency.
        try:
            listing = gh("api", f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100&created=%3E%3D{state['created']}", timeout=5)
            matches = [item for item in listing.get("workflow_runs", [])
                       if item.get("display_title", "").startswith(f"data:{state['correlation']} /")]
            if len(matches) == 1:
                run = state['run'] = matches[0]
            elif len(matches) > 1:
                state['resolution'] = 'ambiguous_correlated_children'
        except Exception:
            state['resolution'] = 'correlated_child_lookup_failed'
    receipt = {
        'schema': 1, 'workflow': WORKFLOW, 'correlation_id': state['correlation'],
        'environment': state['environment'], 'reason': reason,
        'run_id': run['id'] if run else None, 'cancel_requested': False,
        'observed_status': run.get('status', 'unknown') if run else 'unresolved',
        'resolution': state.get('resolution', 'exact_correlated_child'),
        'database_state': 'unverified', 'restart_requires_state_verification': True,
    }
    def save():
        if os.environ.get('RUNNER_TEMP'):
            directory = Path(os.environ['RUNNER_TEMP']) / 'environment-data-dispatch'
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            (directory / 'interrupted-dispatch.json').write_text(json.dumps(receipt, sort_keys=True) + '\n')
    save()  # Preserve the locator before cancellation/network requests.
    if run and run.get('status') != 'completed':
        try:
            gh('api', '--method', 'POST', f"repos/{REPOSITORY}/actions/runs/{run['id']}/cancel", timeout=5)
            receipt['cancel_requested'] = True
            receipt['observed_status'] = 'cancellation_requested_not_confirmed'
            # Observe the same run id briefly so the receipt distinguishes a
            # completed cancellation from a request whose outcome is unknown.
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                current = gh('api', f"repos/{REPOSITORY}/actions/runs/{run['id']}", timeout=5)
                receipt['observed_status'] = current.get('status', 'unknown')
                receipt['conclusion'] = current.get('conclusion')
                if current.get('status') == 'completed':
                    break
                time.sleep(3)
        except Exception:
            if receipt['observed_status'] != 'completed':
                receipt['observed_status'] = 'cancellation_or_observation_unconfirmed'
        save()
    print('::warning::Data dispatch stopped; verify the exact child and database state before retrying. '
          f"Correlation: {state['correlation']}; run: {receipt['run_id'] or 'unresolved'}.", flush=True)


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
    for field in ("candidate_run_id", "rehearsal_run_id", "expected_schema_version", "target_schema_version", "migration_sha256"):
        if os.environ.get(field.upper()):
            inputs[field] = os.environ[field.upper()]
    # Validate JSON before dispatch; never echo its potentially private contents.
    config = json.loads(inputs["config_json"])
    if not isinstance(config, dict):
        raise SystemExit("Data configuration must be an object")
    validate_config(config, inputs['mode'])
    for field in ("candidate_run_id", "rehearsal_run_id", "expected_schema_version", "target_schema_version", "migration_sha256"):
        if field not in inputs and config.get(field):
            inputs[field] = str(config[field])
    created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    state = {'correlation': correlation, 'environment': inputs['environment'], 'run': None,
             'created': created}
    previous_handlers = {}
    def interrupt(signum, frame):
        raise SystemExit('Parent interrupted; child and database state require verification')
    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, interrupt)
    dispatched = False
    try:
        # A POST error can have an unknown outcome: retain correlation, never retry it automatically.
        dispatched = True
        gh("api", "--method", "POST", f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/dispatches",
           "--input", "-", payload={"ref": ref, "inputs": inputs})
        deadline = time.monotonic() + int(os.environ.get("DATA_WAIT_SECONDS", "7200"))
        while time.monotonic() < deadline:
            run = state['run']
            if run is None:
                listing = gh("api", f"repos/{REPOSITORY}/actions/workflows/{WORKFLOW}/runs?event=workflow_dispatch&per_page=100&created=%3E%3D{created}")
                matches = [item for item in listing["workflow_runs"]
                           if item.get("display_title", "").startswith(f"data:{correlation} /")]
                if len(matches) > 1:
                    raise SystemExit("Ambiguous child execution; refusing to guess")
                if matches:
                    run = state['run'] = matches[0]
                    print("Data operation:", run["html_url"], flush=True)
            else:
                run = state['run'] = gh("api", f"repos/{REPOSITORY}/actions/runs/{run['id']}")
            if run and run["status"] == "completed":
                if run["conclusion"] != "success":
                    raise SystemExit(f"Data operation failed: {run['html_url']} ({run['conclusion']})")
                if os.environ.get("GITHUB_OUTPUT"):
                    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                        output.write(f"data_run_id={run['id']}\ndata_run_url={run['html_url']}\n")
                return
            time.sleep(10)
        raise SystemExit("Child timeout (not acceptance); inspect correlated run before retrying")
    except BaseException:
        if dispatched:
            stop_child(state, 'dispatch_interrupted_or_failed')
        raise
    finally:
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)


if __name__ == "__main__":
    main()
