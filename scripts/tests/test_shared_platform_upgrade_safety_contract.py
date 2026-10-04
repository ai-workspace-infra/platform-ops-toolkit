"""Shared open-platform upgrades must never silently destroy persistent state."""
import os
import subprocess
import sys
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
        self.assertIn("observability_operations.yml", https["run"])
        self.assertIn("observability_operation=verify_target", https["run"])
        self.assertEqual(https["working-directory"], "playbooks")

    def test_observability_data_and_health_execution_is_delegated_to_playbooks(self):
        document = load("observability-server.yml")
        expected = {
            "historical_data": "data_migrate",
            "verify_stores": "verify_store",
            "verify_target": "verify_target",
            "verify_mcp_matrix": "verify_mcp",
        }
        for job_name, operation in expected.items():
            job = document["jobs"][job_name]
            steps = job["steps"]
            role_checkout = next(
                index for index, step in enumerate(steps)
                if step.get("name", "").startswith("Checkout Playbooks Observability role")
            )
            runner_setup = next(
                index for index, step in enumerate(steps)
                if step.get("name") == "Install Ansible runtime"
            )
            calls = [step for step in steps if operation in step.get("run", "")]
            self.assertTrue(calls, f"{job_name} must invoke {operation}")
            self.assertLess(role_checkout, runner_setup)
            for call in calls:
                self.assertIn("observability_operations.yml", call["run"])
                self.assertEqual(call["working-directory"], "playbooks")
                self.assertIn("observability_operations_environment=uat", call["run"])
                if job_name == "verify_mcp_matrix":
                    self.assertTrue(call.get("if", "").startswith("matrix.enabled"))


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


class SpotVmRuntimeReconcileTests(unittest.TestCase):
    """Shared service callers use the reviewed IaC execution owner."""

    def test_shared_service_deploys_start_the_declared_vm_before_use(self):
        zitadel = load("zitadel-server.yml")["jobs"]["dns"]["steps"]
        names = [step.get("name") for step in zitadel]
        self.assertLess(names.index("Start the declared IAM VM if GCP stopped it"), names.index("Point IAM DNS to declared VM"))
        service = (ROOT / ".github/scripts/service-deploy/zitadel.sh").read_text()
        self.assertLess(service.index("iac_modules/scripts/pipeline/ensure-gcp-vm-running.py"), service.index("IAM VM is not RUNNING"))
        observability = next(
            step for step in load("observability-server.yml")["jobs"]["deploy_shared_target"]["steps"]
            if step.get("name") == "Resolve declared shared GCP node and public address"
        )["run"]
        self.assertLess(
            observability.index("iac_modules/scripts/pipeline/ensure-gcp-vm-running.py"),
            observability.index("Shared Observability VM is not RUNNING"),
        )



class ZitadelUnbootstrappedRecoveryTests(unittest.TestCase):
    """The ZITADEL database reset is explicit, confirmed and never upgrade-driven."""

    TOKEN = "RESET-ZITADEL-DATABASE"

    def setUp(self):
        self.workflow = load("zitadel-server.yml")
        on = self.workflow.get("on") or self.workflow[True]
        self.inputs = on["workflow_dispatch"]["inputs"]
        self.validate = next(
            step["run"] for step in self.workflow["jobs"]["declaration"]["steps"]
            if step.get("name") == "Validate one-time recovery request"
        )

    def validation(self, confirmation, stage="deploy", action="none", dns="none"):
        env = dict(os.environ, RESET_CONFIRMATION=confirmation, SERVICE_STAGE=stage,
                   DEPLOY_ACTION=action, DNS_ACTION=dns)
        return subprocess.run(["bash", "-c", self.validate], env=env, capture_output=True, text=True).returncode

    def test_input_is_optional_and_empty_by_default(self):
        spec = self.inputs["reset_unbootstrapped_confirmation"]
        self.assertEqual(spec["default"], "")
        self.assertFalse(spec["required"])

    def test_only_the_exact_token_with_a_plain_deploy_is_accepted(self):
        self.assertEqual(self.validation(""), 0)
        self.assertEqual(self.validation(self.TOKEN), 0)
        self.assertNotEqual(self.validation("reset"), 0)
        self.assertNotEqual(self.validation(self.TOKEN.lower()), 0)
        self.assertNotEqual(self.validation(self.TOKEN, stage="verify"), 0)
        self.assertNotEqual(self.validation(self.TOKEN, action="apply"), 0)
        self.assertNotEqual(self.validation(self.TOKEN, dns="update"), 0)

    def test_playbook_flag_is_set_only_for_the_exact_token(self):
        script = (ROOT / ".github/scripts/service-deploy/zitadel.sh").read_text()
        self.assertIn('== "RESET-ZITADEL-DATABASE":', script)
        self.assertIn('extra["zitadel_reset_unbootstrapped_instance"] = True', script)
        deploy = next(
            step for step in self.workflow["jobs"]["service"]["steps"]
            if step.get("name") == "Deploy or verify ZITADEL"
        )
        self.assertEqual(deploy["env"]["RESET_UNBOOTSTRAPPED_CONFIRMATION"],
                         "${{ inputs.reset_unbootstrapped_confirmation }}")

    def test_orchestrator_never_requests_the_reset(self):
        orchestrator = (WORKFLOWS / "open-platform-orchestrator.yml").read_text()
        self.assertNotIn("reset_unbootstrapped_confirmation", orchestrator)
        self.assertNotIn(self.TOKEN, orchestrator)


class ZitadelServiceOperationsTests(unittest.TestCase):
    """ZITADEL service health and failure evidence belong to the Playbooks
    operations role; Toolkit calls it at a reviewed SHA and judges the result."""

    SCRIPT = ROOT / ".github/scripts/service-deploy/zitadel.sh"

    def verify_stage(self, ansible_rc=0, with_entry=True):
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp) / "workspace"
            operations = workspace / "playbooks-operations"
            operations.mkdir(parents=True)
            if with_entry:
                (operations / "zitadel_operations.yml").write_text("---\n")
            stubs = Path(tmp) / "bin"
            stubs.mkdir()
            log = Path(tmp) / "calls.log"
            (stubs / "ansible-playbook").write_text(
                f'#!/usr/bin/env bash\nprintf "%s|%s\\n" "$PWD" "$*" >> "{log}"\nexit {ansible_rc}\n')
            (stubs / "python3").write_text(
                f'#!/usr/bin/env bash\nif [[ "$1 $2" == "-m pip" ]]; then printf "pip %s\\n" "$*" >> "{log}"; exit 0; fi\n'
                f'exec {sys.executable} "$@"\n')
            for stub in stubs.iterdir():
                stub.chmod(0o755)
            env = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}", GITHUB_WORKSPACE=str(workspace),
                       DOMAIN="iam.svc.plus", SERVICE_STAGE="verify")
            result = subprocess.run(["bash", str(self.SCRIPT)], env=env, cwd=workspace,
                                    capture_output=True, text=True)
            return result, (log.read_text() if log.exists() else ""), str(operations)

    def test_verify_stage_runs_the_reviewed_public_operation(self):
        result, calls, operations = self.verify_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = calls.splitlines()
        self.assertTrue(lines[0].startswith("pip -m pip install") and "ansible-core" in lines[0])
        self.assertEqual(lines[1], f"{operations}|-i localhost, zitadel_operations.yml "
                                   "-e zitadel_operation=verify_public -e zitadel_operations_target=localhost "
                                   "-e zitadel_operations_domain=iam.svc.plus -c local")

    def test_a_failed_operation_fails_the_stage(self):
        result, _, _ = self.verify_stage(ansible_rc=2)
        self.assertNotEqual(result.returncode, 0)

    def test_a_missing_operations_entry_fails_before_any_check(self):
        result, calls, _ = self.verify_stage(with_entry=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "")

    def test_deploy_verifies_the_same_single_host_then_reports(self):
        text = self.SCRIPT.read_text()
        call = 'run_operation "${access_dir}/inventory.json" "${NODE_NAME}" verify_host'
        self.assertLess(text.index("deploy_iam_domain.yml"), text.index(call))
        self.assertLess(text.index(call), text.index("### ZITADEL server"))
        failure = text[text.index(call):text.index("### ZITADEL server")]
        self.assertIn("exit 1", failure)
        # No second copy of the service checks or host diagnostics in Toolkit.
        for owned_by_playbooks in ("openid-configuration", "verify()", "journalctl", "ss -ltnp", "systemctl"):
            self.assertNotIn(owned_by_playbooks, text)

    def test_operations_checkout_is_pinned_unconditional_and_credential_free(self):
        steps = load("zitadel-server.yml")["jobs"]["service"]["steps"]
        names = [step.get("name") for step in steps]
        checkout = steps[names.index("Checkout reviewed Playbooks ZITADEL operations")]
        options = checkout["with"]
        self.assertEqual(options["repository"], "ai-workspace-infra/playbooks")
        self.assertRegex(options["ref"], r"^[0-9a-f]{40}$")
        self.assertEqual(options["path"], "playbooks-operations")
        self.assertIs(options["persist-credentials"], False)
        self.assertEqual(set(options["sparse-checkout"].split()),
                         {"zitadel_operations.yml", "roles/docker/zitadel_server_operations"})
        self.assertNotIn("if", checkout)
        self.assertLess(names.index("Checkout reviewed Playbooks ZITADEL operations"),
                        names.index("Deploy or verify ZITADEL"))


if __name__ == "__main__":
    unittest.main()
