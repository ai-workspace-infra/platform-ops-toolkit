"""Shared open-platform upgrades must never silently destroy persistent state."""
import os
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


class ZitadelHttpsVerificationTests(unittest.TestCase):
    """A failed iam.svc.plus check must fail the deploy, with host evidence."""

    SCRIPT = ROOT / ".github/scripts/service-deploy/zitadel.sh"

    def verify_in_condition(self, curl_body, curl_rc=0):
        text = self.SCRIPT.read_text()
        start = text.index("verify() {")
        end = text.index("\n}\n", start) + 3
        with tempfile.TemporaryDirectory() as tmp:
            curl = Path(tmp) / "curl"
            curl.write_text(f"#!/usr/bin/env bash\nprintf '%s' '{curl_body}'\nexit {curl_rc}\n")
            curl.chmod(0o755)
            harness = "set -euo pipefail\n" + text[start:end] + "\nif ! verify; then echo FAILED; exit 3; fi\necho PASSED\n"
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", DOMAIN="iam.svc.plus")
            return subprocess.run(["bash", "-c", harness], env=env, capture_output=True, text=True)

    def test_verify_fails_in_a_condition_when_https_is_unreachable(self):
        # set -e is off inside `if ! verify`; each check must return explicitly.
        result = self.verify_in_condition("", curl_rc=7)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)

    def test_verify_rejects_a_wrong_issuer_and_accepts_the_right_one(self):
        wrong = self.verify_in_condition('{"issuer":"https://evil.example","jwks_uri":"https://evil.example/k"}')
        self.assertEqual(wrong.returncode, 3)
        right = self.verify_in_condition('{"issuer":"https://iam.svc.plus","jwks_uri":"https://iam.svc.plus/oauth/v2/keys"}')
        self.assertEqual(right.returncode, 0, right.stderr)
        self.assertIn("PASSED", right.stdout)

    def test_deploy_collects_read_only_host_evidence_and_still_fails(self):
        text = self.SCRIPT.read_text()
        block = text[text.index("if ! verify; then"):text.index("printf '### ZITADEL server")]
        for evidence in ("systemctl is-active caddy", "ss -ltnp", "journalctl -u caddy", "--resolve ${DOMAIN}:443:127.0.0.1"):
            self.assertIn(evidence, block)
        commands = block[block.index("<<EOF"):block.index("\nEOF\n")]
        import re
        self.assertIsNone(re.search(r"systemctl (restart|reload|stop|start|enable|disable)|\\bdocker\\b|\\brm\\b|caddy (reload|stop|start)", commands))
        self.assertTrue(block.rstrip().endswith("exit 1\nfi") or "  exit 1\nfi" in block)

if __name__ == "__main__":
    unittest.main()
