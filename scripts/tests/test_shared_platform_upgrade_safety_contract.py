"""Shared open-platform upgrades must never silently destroy persistent state."""
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
        self.assertIn("--exit-status", script)
        order = [
            script.index("dispatch_and_wait vault-server.yml"),
            script.index("dispatch_and_wait zitadel-server.yml"),
            script.index("dispatch_and_wait observability-server.yml"),
        ]
        self.assertEqual(order, sorted(order))


if __name__ == "__main__":
    unittest.main()
