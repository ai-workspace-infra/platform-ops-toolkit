"""Shared open-platform upgrades must never silently destroy persistent state."""
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"


def load(name):
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


class GcpApplyGuardTests(unittest.TestCase):
    def setUp(self):
        steps = load("gcp-iac-pipeline.yml")["jobs"]["gcp-platform"]["steps"]
        self.steps = {step.get("name"): step for step in steps}

    def test_apply_runs_only_the_inspected_plan(self):
        plan = self.steps["Terraform plan"]["run"]
        apply = self.steps["Terraform apply"]["run"]
        self.assertIn('-out="${PLAN_FILE}"', plan)
        self.assertIn('apply -input=false -auto-approve "${PLAN_FILE}"', apply)
        # Re-planning at apply time would skip the inspection below.
        self.assertNotIn("-var-file", apply)

    def test_persistent_environments_refuse_delete_or_replace(self):
        plan = self.steps["Terraform plan"]["run"]
        self.assertIn('"${DEPLOY_ENV}" == shared || "${DEPLOY_ENV}" == prod', plan)
        self.assertIn('show -json "${PLAN_FILE}"', plan)
        self.assertIn('select(.change.actions | index("delete"))', plan)
        self.assertIn("exit 1", plan)

    def test_guard_reads_json_from_the_unwrapped_terraform_binary(self):
        plan = self.steps["Terraform plan"]["run"]
        self.assertIn('"${TERRAFORM_CLI_PATH}/terraform-bin"', plan)

    def test_shared_destroy_stays_disabled(self):
        config = self.steps["Resolve and validate GCP resource manifest"]["run"]
        self.assertIn('"${GCP_ENVIRONMENT}" == shared && "${DEPLOY_ACTION}" == destroy', config)


class SharedObservabilityVerificationTests(unittest.TestCase):
    def test_every_shared_gcp_deploy_runs_https_and_store_checks(self):
        job = load("observability-server.yml")["jobs"]["verify_target"]
        condition = job["if"]
        self.assertIn("inputs.target_platform == 'shared-gcp')", condition)
        self.assertNotIn("inputs.target_platform == 'shared-gcp' && inputs.dns_action == 'cutover'", condition)
        https = next(step for step in job["steps"] if step.get("name") == "Verify shared GCP Observability HTTPS target")
        self.assertIn("/grafana/api/health", https["run"])
        for store in ("victoriametrics", "victorialogs", "victoriatraces"):
            self.assertIn(store, https["run"])


class OrchestratorUpgradeBoundaryTests(unittest.TestCase):
    def test_upgrade_never_migrates_or_destroys(self):
        document = load("open-platform-orchestrator.yml")
        on = document.get("on") or document[True]
        self.assertNotIn("destroy", on["workflow_dispatch"]["inputs"]["operation"]["options"])
        contract = document["jobs"]["contract"]["steps"][1]["run"]
        self.assertIn("shared open-platform never supports destroy", contract)
        self.assertIn('[[ "${VAULT_STAGE}" == none && "${OBS_MIGRATION}" == none ]]', contract)

    def test_services_run_vault_then_zitadel_then_observability_and_stop_on_failure(self):
        document = load("open-platform-orchestrator.yml")
        script = next(
            step for step in document["jobs"]["services"]["steps"]
            if step.get("name") == "Dispatch and wait for shared service workflows"
        )["run"]
        self.assertTrue(script.lstrip().startswith("set -euo pipefail"))
        # Only an explicit success conclusion of the child counts; no gh run watch,
        # which exits on a transient API error while the child keeps running.
        self.assertIn('[[ "${conclusion}" == success ]]', script)
        self.assertNotIn("gh run watch", script)
        order = [
            script.index("dispatch_and_wait vault-server.yml"),
            script.index("dispatch_and_wait zitadel-server.yml"),
            script.index("dispatch_and_wait observability-server.yml"),
        ]
        self.assertEqual(order, sorted(order))


ENSURE_VM = ROOT / ".github/scripts/service-deploy/ensure-declared-vm-running.sh"
FAKE_GCLOUD = """#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "${GCLOUD_LOG}"
if [[ "$1 $2 $3" == "compute operations list" ]]; then
  [[ -z "${OPERATIONS_DENIED:-}" ]] || { echo 'PERMISSION_DENIED' >&2; exit 1; }
  echo "2026-09-30T13:26:00Z stop DONE"; exit 0
fi
case "$3" in
  describe)
    [[ -e "${STATE_FILE}" ]] || { echo 'ERROR: instance not found' >&2; exit 1; }
    if [[ "$*" == *lastStopTimestamp* ]]; then echo "2026-09-30T13:26:30Z"; exit 0; fi
    cat "${STATE_FILE}" ;;
  start|resume)
    echo RUNNING > "${STATE_FILE}" ;;
  *)
    echo "unexpected gcloud call: $*" >&2; exit 9 ;;
esac
"""


class SpotVmRuntimeReconcileTests(unittest.TestCase):
    """A preempted Spot VM is started in place; nothing is ever created."""

    def run_ensure(self, status, **extra_env):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            gcloud = tmp / "gcloud"
            gcloud.write_text(FAKE_GCLOUD)
            gcloud.chmod(gcloud.stat().st_mode | stat.S_IEXEC)
            state, log = tmp / "state", tmp / "gcloud.log"
            if status is not None:
                state.write_text(status + "\n")
            env = dict(
                os.environ, PATH=f"{tmp}:{os.environ['PATH']}", GCLOUD_LOG=str(log), STATE_FILE=str(state),
                PROJECT_ID="p", NODE_NAME="iam-shared-0", NODE_ZONE="asia-east1-a",
                VM_START_TIMEOUT_SECONDS="3", VM_START_POLL_SECONDS="1", **extra_env,
            )
            result = subprocess.run(["bash", str(ENSURE_VM)], env=env, capture_output=True, text=True)
            calls = log.read_text().splitlines() if log.exists() else []
            self.stdout = result.stdout
            # Only instance actions matter for safety; evidence reads are separate.
            return result, [call.split()[2] for call in calls if call.startswith("compute instances ")]

    def test_stopped_vm_is_started_once_then_running(self):
        result, calls = self.run_ensure("TERMINATED")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("start"), 1)
        self.assertEqual(calls[-1], "describe")
        # The stop evidence is recorded before the start, without the principal.
        self.assertIn("2026-09-30T13:26:30Z", self.stdout)
        self.assertIn("stop DONE", self.stdout)
        self.assertLess(self.stdout.index("stop record"), self.stdout.index("starting the existing instance"))

    def test_unreadable_operations_do_not_block_the_start(self):
        result, calls = self.run_ensure("TERMINATED", OPERATIONS_DENIED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("start"), 1)
        self.assertIn("Could not list GCP operations", self.stdout)

    def test_running_vm_is_left_alone(self):
        result, calls = self.run_ensure("RUNNING")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["describe"])

    def test_suspended_vm_is_resumed(self):
        result, calls = self.run_ensure("SUSPENDED")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count("resume"), 1)

    def test_missing_vm_fails_without_creating_one(self):
        result, calls = self.run_ensure(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["describe"])

    def test_script_never_creates_replaces_or_deletes(self):
        script = ENSURE_VM.read_text()
        for verb in ("instances create", "instances delete", "disks ", "--force", "|| true", "principalEmail", "user)"):
            self.assertNotIn(verb, script)

    def test_shared_service_deploys_start_the_declared_vm_before_use(self):
        zitadel = load("zitadel-server.yml")["jobs"]["dns"]["steps"]
        names = [step.get("name") for step in zitadel]
        self.assertLess(names.index("Start the declared IAM VM if GCP stopped it"), names.index("Point IAM DNS to declared VM"))
        service = (ROOT / ".github/scripts/service-deploy/zitadel.sh").read_text()
        self.assertLess(service.index("ensure-declared-vm-running.sh"), service.index("IAM VM is not RUNNING"))
        observability = next(
            step for step in load("observability-server.yml")["jobs"]["deploy_shared_target"]["steps"]
            if step.get("name") == "Resolve declared shared GCP node and public address"
        )["run"]
        self.assertLess(
            observability.index("ensure-declared-vm-running.sh"),
            observability.index("Shared Observability VM is not RUNNING"),
        )


if __name__ == "__main__":
    unittest.main()
