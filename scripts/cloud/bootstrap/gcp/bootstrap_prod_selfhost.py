#!/usr/bin/env python3
"""PROD one-time bootstrap controller; provider execution belongs to fixed IaC.

Use --check to inspect the pinned source contract without Vault or provider
access. Administrator bootstrap credentials stay in the child environment.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

IAC_REF = "d7065ddc352726985f5e3d9351c147d5a28219e2"
GITOPS_REF = "0385d939a4d937682768849a7d32fe74c9b09d01"
OWNER_PATH = "terraform-hcl-standard/gcp-cloud/scripts/bootstrap_prod_selfhost.py"
BOOTSTRAP_PATH = "kv/CICD/prod/gcp-bootstrap/xworktech"
STATE_PATH = "kv/CICD/prod/iac_state"
STATE_KEYS = ("TF_STATE_ENDPOINT", "TF_STATE_BUCKET", "TF_STATE_ACCESS_KEY",
              "TF_STATE_SECRET_KEY", "TF_STATE_REGION")


class ControllerError(Exception):
    pass


def verify_checkout(path, ref, repository):
    if not re.fullmatch(r"[0-9a-f]{40}", ref):
        raise ControllerError("bootstrap owner has not been pinned to a full commit")
    try:
        head = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
        remote = subprocess.check_output(["git", "-C", str(path), "remote", "get-url", "origin"], text=True).strip()
        status = subprocess.check_output(["git", "-C", str(path), "status", "--porcelain", "--untracked-files=all"], text=True)
    except subprocess.CalledProcessError as exc:
        raise ControllerError("cannot verify fixed source checkout") from exc
    if head != ref or remote not in (f"https://github.com/{repository}.git", f"https://github.com/{repository}",
                                   f"git@github.com:{repository}.git") or status:
        raise ControllerError("source must be a clean checkout of the expected repository and fixed commit")


def vault_record(path, env):
    # Never echo Vault output, token, arbitrary error text or credential values.
    try:
        result = subprocess.run(["vault", "kv", "get", "-format=json", path], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode:
            raise ControllerError(f"cannot read approved Vault contract: {path}")
        return json.loads(result.stdout)["data"]["data"]
    except (OSError, ValueError, KeyError) as exc:
        raise ControllerError(f"invalid or unavailable Vault contract: {path}") from exc


def runtime_environment():
    env = dict(os.environ)
    env["VAULT_ADDR"] = "https://vault.svc.plus"
    # Explicitly injected short-lived credentials can be used by the approved
    # administrator; otherwise read only the existing approved bootstrap path.
    if not env.get("GCP_BOOTSTRAP_ACCESS_TOKEN"):
        record = vault_record(BOOTSTRAP_PATH, env)
        if record.get("GCP_PROJECT_ID") != "open-platform-prod":
            raise ControllerError("bootstrap Vault project differs from PROD declaration")
        token = record.get("GCP_ACCESS_TOKEN")
        if not isinstance(token, str) or not token.strip():
            raise ControllerError("approved short-lived bootstrap token is missing; administrator repair remains pending")
        env["GCP_BOOTSTRAP_ACCESS_TOKEN"] = token
    if not all(env.get(key) for key in STATE_KEYS):
        record = vault_record(STATE_PATH, env)
        for key in STATE_KEYS:
            if not isinstance(record.get(key), str) or not record[key].strip():
                raise ControllerError(f"Vault state contract is missing {key}")
            env[key] = record[key]
    return env


def execute(args):
    iac = args.iac_dir.resolve()
    gitops = args.gitops_dir.resolve()
    verify_checkout(iac, IAC_REF, "ai-workspace-infra/iac_modules")
    verify_checkout(gitops, GITOPS_REF, "ai-workspace-infra/gitops")
    owner = iac / OWNER_PATH
    if not owner.is_file():
        raise ControllerError("fixed IaC bootstrap owner is missing")
    if args.check:
        return {"result": "source-contract-verified", "owner": "iac_modules", "iac_ref": IAC_REF,
                "gitops_ref": GITOPS_REF, "stage": args.stage, "bootstrap_path": BOOTSTRAP_PATH,
                "runtime_identity": "github-actions-prod@open-platform-prod.iam.gserviceaccount.com",
                "live_bootstrap_verified": False, "database_cutover_approved": False}
    command = [sys.executable, str(owner), "--gitops-dir", str(gitops), "--gitops-ref", GITOPS_REF,
               "--iac-ref", IAC_REF, "--stage", args.stage, "--action", args.action]
    if args.action == "apply":
        if not re.fullmatch(r"[0-9a-f]{64}", args.approved_plan_sha256 or ""):
            raise ControllerError("apply requires the administrator-reviewed plan digest")
        command.extend(["--approved-plan-sha256", args.approved_plan_sha256])
    # This is a fixed owner invocation, not provider/host/DB execution in Toolkit.
    result = subprocess.run(command, env=runtime_environment(), stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    if result.returncode:
        # This fixed owner emits a single sanitized guard reason. Do not pass
        # Python tracebacks or arbitrary provider diagnostics through.
        reason = result.stderr.strip()
        if re.fullmatch(r"bootstrap stopped: [A-Za-z0-9 /;,:._()=-]{1,220}", reason):
            raise ControllerError(f"fixed IaC owner: {reason}")
        raise ControllerError("fixed IaC bootstrap stopped; no convergence receipt was issued")
    try:
        receipt = json.loads(result.stdout)
    except ValueError as exc:
        raise ControllerError("IaC returned an invalid bootstrap receipt") from exc
    expected = "converged" if args.action == "apply" else "review-required"
    if (receipt.get("owner") != "iac_modules" or receipt.get("scope") != "prod-selfhost-bootstrap-only"
            or receipt.get("iac_ref") != IAC_REF or receipt.get("gitops_ref") != GITOPS_REF
            or receipt.get("stage") != args.stage or receipt.get("action") != args.action
            or receipt.get("result") != expected or receipt.get("database_cutover_approved") is not False):
        raise ControllerError("IaC receipt does not match the fixed bootstrap request")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iac-dir", type=Path, required=True)
    parser.add_argument("--gitops-dir", type=Path, required=True)
    parser.add_argument("--stage", choices=("identity", "external-ip"), required=True)
    parser.add_argument("--action", choices=("plan", "apply"), default="plan")
    parser.add_argument("--approved-plan-sha256")
    parser.add_argument("--check", action="store_true", help="Verify fixed sources without credentials or resource access.")
    try:
        print(json.dumps(execute(parser.parse_args()), indent=2, sort_keys=True))
    except ControllerError as exc:
        print(f"bootstrap controller stopped: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
