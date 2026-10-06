import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "cloud" / "bootstrap" / "gcp" / "bootstrap_prod_selfhost.py"
SPEC = importlib.util.spec_from_file_location("controller", SCRIPT)
controller = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(controller)


class BootstrapControllerTests(unittest.TestCase):
    def test_fixed_commits_and_owner_path(self):
        self.assertRegex(controller.IAC_REF, r"^[0-9a-f]{40}$")
        self.assertRegex(controller.GITOPS_REF, r"^[0-9a-f]{40}$")
        self.assertEqual(controller.OWNER_PATH, "terraform-hcl-standard/gcp-cloud/scripts/bootstrap_prod_selfhost.py")

    def test_no_direct_provider_execution(self):
        source = SCRIPT.read_text()
        for command in ('["terraform"', '["gcloud"', '["ssh"', '["psql"', '["aws"', '["wrangler"'):
            self.assertNotIn(command, source)
        self.assertNotIn("urllib.request", source)

    def test_runtime_credential_missing_fails_without_echoing_vault(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(controller, "vault_record", return_value={"GCP_PROJECT_ID": "open-platform-prod"}):
            with self.assertRaisesRegex(controller.ControllerError, "administrator repair remains pending"):
                controller.runtime_environment()

    def test_approved_runtime_token_and_state_remain_environment_only(self):
        env = {key: "fixture" for key in controller.STATE_KEYS}
        env["GCP_BOOTSTRAP_ACCESS_TOKEN"] = "short-test-token"
        with patch.dict(os.environ, env, clear=True), patch.object(controller, "vault_record") as vault:
            runtime = controller.runtime_environment()
        vault.assert_not_called()
        self.assertEqual(runtime["GCP_BOOTSTRAP_ACCESS_TOKEN"], "short-test-token")
        self.assertEqual(runtime["VAULT_ADDR"], "https://vault.svc.plus")

    def test_partial_state_environment_is_replaced_from_one_vault_record(self):
        state = {key: "approved" for key in controller.STATE_KEYS}
        with patch.dict(os.environ, {"GCP_BOOTSTRAP_ACCESS_TOKEN": "token", "TF_STATE_BUCKET": "wrong"}, clear=True), \
             patch.object(controller, "vault_record", return_value=state) as vault:
            env = controller.runtime_environment()
        self.assertEqual(env["TF_STATE_BUCKET"], "approved")
        self.assertEqual(vault.call_args.args[0], controller.STATE_PATH)

    def test_check_never_reads_secrets_or_invokes_owner(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            owner = root / controller.OWNER_PATH
            owner.parent.mkdir(parents=True)
            owner.touch()
            args = SimpleNamespace(iac_dir=root, gitops_dir=root, stage="identity", action="plan", check=True)
            with patch.object(controller, "verify_checkout"), patch.object(controller, "runtime_environment") as secrets, \
                 patch.object(controller.subprocess, "run") as invoke:
                receipt = controller.execute(args)
            secrets.assert_not_called()
            invoke.assert_not_called()
            self.assertFalse(receipt["live_bootstrap_verified"])
            self.assertFalse(receipt["database_cutover_approved"])

    def test_owner_failure_bad_receipt_and_request_mismatch_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            owner = root / controller.OWNER_PATH
            owner.parent.mkdir(parents=True)
            owner.touch()
            args = SimpleNamespace(iac_dir=root, gitops_dir=root, stage="identity", action="plan", check=False)
            for result in (SimpleNamespace(returncode=1, stdout="secret-value", stderr="secret-value"),
                           SimpleNamespace(returncode=0, stdout="not-json", stderr=""),
                           SimpleNamespace(returncode=0, stdout=json.dumps({"owner": "other"}), stderr="")):
                with patch.object(controller, "verify_checkout"), patch.object(controller, "runtime_environment", return_value={}), \
                     patch.object(controller.subprocess, "run", return_value=result):
                    with self.assertRaises(controller.ControllerError) as error:
                        controller.execute(args)
                self.assertNotIn("secret-value", str(error.exception))

    def test_owner_invocation_pins_sources_and_does_not_expose_token_in_arguments(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            owner = root / controller.OWNER_PATH
            owner.parent.mkdir(parents=True)
            owner.touch()
            args = SimpleNamespace(iac_dir=root, gitops_dir=root, stage="identity", action="plan", check=False)
            receipt = {"owner": "iac_modules", "scope": "prod-selfhost-bootstrap-only", "iac_ref": controller.IAC_REF,
                       "gitops_ref": controller.GITOPS_REF, "stage": "identity", "action": "plan", "result": "review-required",
                       "database_cutover_approved": False}
            result = SimpleNamespace(returncode=0, stdout=json.dumps(receipt), stderr="")
            with patch.object(controller, "verify_checkout"), \
                 patch.object(controller, "runtime_environment", return_value={"GCP_BOOTSTRAP_ACCESS_TOKEN": "test-token"}), \
                 patch.object(controller.subprocess, "run", return_value=result) as invoke:
                self.assertEqual(controller.execute(args), receipt)
            command = invoke.call_args.args[0]
            self.assertIn(controller.IAC_REF, command)
            self.assertIn(controller.GITOPS_REF, command)
            self.assertNotIn("test-token", command)
            self.assertEqual(invoke.call_args.kwargs["env"]["GCP_BOOTSTRAP_ACCESS_TOKEN"], "test-token")


if __name__ == "__main__":
    unittest.main()
