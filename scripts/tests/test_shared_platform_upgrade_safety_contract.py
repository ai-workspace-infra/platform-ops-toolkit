"""Shared open-platform upgrades must never silently destroy persistent state."""
import json
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
        service = load("zitadel-server.yml")["jobs"]["service"]["steps"]
        service_names = [step.get("name") for step in service]
        # The IaC access executor reconciles the VM to RUNNING before it opens SSH.
        access = service[service_names.index("Open temporary SSH access to the IAM VM")]
        self.assertEqual(access["run"], "./iac_modules/scripts/pipeline/gcp-temporary-ssh-access.sh open")
        self.assertNotIn("ENSURE_RUNNING", access["env"])
        self.assertLess(service_names.index("Open temporary SSH access to the IAM VM"),
                        service_names.index("Deploy ZITADEL with Playbooks"))
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

    def render(self, confirmation, instance="iam-shared-0"):
        step = next(
            step for step in self.workflow["jobs"]["service"]["steps"]
            if step.get("name") == "Render the IAM inventory and deploy inputs"
        )
        self.assertEqual(step["shell"], "python")
        self.assertEqual(step["env"]["RESET_UNBOOTSTRAPPED_CONFIRMATION"],
                         "${{ inputs.reset_unbootstrapped_confirmation }}")
        with tempfile.TemporaryDirectory() as tmp:
            access = Path(tmp) / "access.json"
            access.write_text(json.dumps({
                "instance": instance, "target_ip": "34.80.12.34", "ssh_user": "sa_1",
                "private_key": f"{tmp}/id_ed25519", "known_hosts": f"{tmp}/known_hosts"}))
            env = dict(os.environ, ACCESS_FILE=str(access), NODE_NAME="iam-shared-0", DOMAIN="iam.svc.plus",
                       ZITADEL_MASTERKEY="m" * 32, ZITADEL_ADMIN_PASSWORD="Adm1n!pass",
                       RESET_UNBOOTSTRAPPED_CONFIRMATION=confirmation)
            result = subprocess.run([sys.executable, "-c", step["run"]], env=env, capture_output=True, text=True)
            if result.returncode:
                return result.returncode, None, None, None
            extra_file = Path(tmp) / "extra.json"
            return (0, json.loads(extra_file.read_text()), json.loads((Path(tmp) / "inventory.json").read_text()),
                    extra_file.stat().st_mode & 0o777)

    def test_playbook_flag_is_set_only_for_the_exact_token(self):
        _, extra, _, mode = self.render(self.TOKEN)
        self.assertIs(extra["zitadel_reset_unbootstrapped_instance"], True)
        self.assertEqual(extra["zitadel_reset_confirmation"], self.TOKEN)
        self.assertEqual(mode, 0o600)
        for other in ("", "reset", self.TOKEN.lower()):
            _, extra, _, _ = self.render(other)
            self.assertNotIn("zitadel_reset_unbootstrapped_instance", extra)
            self.assertNotIn("zitadel_reset_confirmation", extra)

    def test_inventory_uses_the_iac_access_facts_for_the_declared_host_only(self):
        _, extra, inventory, _ = self.render("")
        self.assertEqual(extra["zitadel_deployment_mode"], "doco-cd")
        host = inventory["all"]["hosts"]["iam-shared-0"]
        self.assertEqual(host["ansible_host"], "34.80.12.34")
        self.assertEqual(host["ansible_user"], "sa_1")
        self.assertTrue(host["ansible_ssh_private_key_file"].endswith("/id_ed25519"))
        self.assertIn("StrictHostKeyChecking=accept-new", host["ansible_ssh_common_args"])
        returncode, _, _, _ = self.render("", instance="another-vm")
        self.assertNotEqual(returncode, 0)

    def test_orchestrator_never_requests_the_reset(self):
        orchestrator = (WORKFLOWS / "open-platform-orchestrator.yml").read_text()
        self.assertNotIn("reset_unbootstrapped_confirmation", orchestrator)
        self.assertNotIn(self.TOKEN, orchestrator)


class ZitadelServiceOperationsTests(unittest.TestCase):
    """Toolkit selects targets, holds credentials and orders the steps; IaC
    Modules opens and revokes host access and Playbooks deploys and verifies."""

    def setUp(self):
        self.steps = load("zitadel-server.yml")["jobs"]["service"]["steps"]
        self.names = [step.get("name") for step in self.steps]

    def step(self, name):
        return self.steps[self.names.index(name)]

    def verify_stage(self, ansible_rc=0):
        run = self.step("Verify ZITADEL public OIDC discovery")["run"]
        with tempfile.TemporaryDirectory() as tmp:
            stubs = Path(tmp) / "bin"
            stubs.mkdir()
            log = Path(tmp) / "calls.log"
            (stubs / "ansible-playbook").write_text(
                f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{log}"\nexit {ansible_rc}\n')
            (stubs / "python3").write_text(
                f'#!/usr/bin/env bash\nif [[ "$1 $2" == "-m pip" ]]; then printf "pip %s\\n" "$*" >> "{log}"; exit 0; fi\n'
                f'exec {sys.executable} "$@"\n')
            for stub in stubs.iterdir():
                stub.chmod(0o755)
            env = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}", DOMAIN="iam.svc.plus")
            result = subprocess.run(["bash", "-e", "-c", run], env=env, cwd=tmp, capture_output=True, text=True)
            return result, (log.read_text() if log.exists() else "")

    def test_verify_stage_runs_the_reviewed_public_operation(self):
        step = self.step("Verify ZITADEL public OIDC discovery")
        self.assertEqual(step["if"], "${{ inputs.service_stage == 'verify' }}")
        self.assertEqual(step["working-directory"], "playbooks-operations")
        result, calls = self.verify_stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = calls.splitlines()
        self.assertTrue(lines[0].startswith("pip -m pip install") and "ansible-core" in lines[0])
        self.assertEqual(lines[1], "-i localhost, -c local zitadel_operations.yml -e zitadel_operation=verify_public "
                                   "-e zitadel_operations_target=localhost -e zitadel_operations_domain=iam.svc.plus")

    def test_a_failed_operation_fails_the_stage(self):
        result, _ = self.verify_stage(ansible_rc=2)
        self.assertNotEqual(result.returncode, 0)

    def test_deploy_order_and_access_is_always_closed(self):
        order = [self.names.index(name) for name in (
            "Check the Vault identity and IAM secrets before host access",
            "Open temporary SSH access to the IAM VM",
            "Require IAM DNS to point only at the IAM VM",
            "Render the IAM inventory and deploy inputs",
            "Deploy ZITADEL with Playbooks",
            "Verify ZITADEL on the IAM host",
            "Close temporary SSH access to the IAM VM",
        )]
        self.assertEqual(order, sorted(order))
        opened = self.step("Open temporary SSH access to the IAM VM")
        closed = self.step("Close temporary SSH access to the IAM VM")
        self.assertEqual(opened["id"], "access")
        self.assertEqual(closed["run"], "./iac_modules/scripts/pipeline/gcp-temporary-ssh-access.sh close")
        self.assertIn("always()", closed["if"])
        self.assertIn("steps.access.outcome != 'skipped'", closed["if"])
        for key in ("GCP_PROJECT_ID", "ACCESS_RULE_NAME", "ACCESS_DIR"):
            self.assertEqual(opened["env"][key], closed["env"][key])
        self.assertIn("${{ github.run_id }}-${{ github.run_attempt }}", opened["env"]["ACCESS_RULE_NAME"])
        deploy = self.step("Deploy ZITADEL with Playbooks")
        self.assertEqual(deploy["working-directory"], "playbooks")
        self.assertIn('deploy_iam_domain.yml \\\n  --limit "${NODE_NAME}"', deploy["run"])
        verify = self.step("Verify ZITADEL on the IAM host")
        self.assertEqual(verify["working-directory"], "playbooks-operations")
        self.assertIn("-e zitadel_operation=verify_host", verify["run"])
        self.assertIn('-e "zitadel_operations_target=${NODE_NAME}"', verify["run"])
        self.assertLess(verify["run"].index("ansible-playbook"), verify["run"].index("### ZITADEL server"))

    def test_dns_precondition_requires_exactly_the_vm_address(self):
        run = self.step("Require IAM DNS to point only at the IAM VM")["run"]
        def check(target):
            env = dict(os.environ, DOMAIN="localhost", TARGET_IP=target)
            return subprocess.run([sys.executable, "-c", run], env=env, capture_output=True, text=True).returncode
        self.assertEqual(check("127.0.0.1"), 0)
        self.assertNotEqual(check("127.0.0.2"), 0)

    def test_owner_checkouts_are_pinned_and_credential_free(self):
        for name, repository, path in (
            ("Checkout reviewed Playbooks ZITADEL operations", "ai-workspace-infra/playbooks", "playbooks-operations"),
            ("Checkout reviewed IaC temporary SSH access executor", "ai-workspace-infra/iac_modules", "iac_modules"),
        ):
            options = self.step(name)["with"]
            self.assertEqual(options["repository"], repository)
            self.assertRegex(options["ref"], r"^[0-9a-f]{40}$")
            self.assertEqual(options["path"], path)
            self.assertIs(options["persist-credentials"], False)
        self.assertNotIn("if", self.step("Checkout reviewed Playbooks ZITADEL operations"))
        self.assertEqual(set(self.step("Checkout reviewed Playbooks ZITADEL operations")["with"]["sparse-checkout"].split()),
                         {"zitadel_operations.yml", "roles/docker/zitadel_server_operations"})

    def test_toolkit_keeps_no_provider_or_service_execution(self):
        runs = "\n".join(step.get("run", "") for step in self.steps)
        for owned_elsewhere in ("os-login", "firewall-rules", "ssh-keygen", "compute instances", "openid-configuration",
                                "journalctl", "systemctl", "service-deploy/zitadel.sh"):
            self.assertNotIn(owned_elsewhere, runs)


if __name__ == "__main__":
    unittest.main()
