import pathlib
import unittest

import yaml


ROOT = pathlib.Path(__file__).resolve().parents[2]
OWNER_SHA = "dbcdc8073228e1749ee88b669dcbfccc0549212d"


class PlaybooksOwnerCallerTests(unittest.TestCase):
    def test_existing_access_keeps_vault_ca_in_toolkit_and_delegates_inventory(self):
        action = ROOT / ".github/actions/node-access-existing/action.yml"
        doc = yaml.safe_load(action.read_text(encoding="utf-8"))
        steps = {step["name"]: step for step in doc["runs"]["steps"]}
        sign = steps["Sign the one-run key with Vault's SSH CA"]["run"]
        self.assertIn("auth/jwt/login", sign)
        contract = steps["Build the existing node's NodeDeployment through Playbooks owner"]
        self.assertEqual(contract["uses"], "./playbooks/.github/actions/node-contract-existing")
        self.assertNotIn("legacy_source.py", action.read_text(encoding="utf-8"))

    def test_vault_host_scripts_resolve_from_the_pinned_owner_checkout(self):
        workflow = ROOT / ".github/workflows/vault-server.yml"
        source = workflow.read_text(encoding="utf-8")
        for script in (
            "legacy_source.py", "prepare_known_hosts.py", "xconnect_stage.py",
            "xconnect_artifacts.sh", "install_vault_drill.sh", "vault_snapshot.sh",
        ):
            self.assertIn(f"playbooks/scripts/node_deploy/{script}", source)
        self.assertIn(f"ref: {OWNER_SHA}", source)

    def test_legacy_copies_remain_for_uat_gated_cleanup(self):
        self.assertTrue((ROOT / ".github/actions/vault-node-stage/action.yml").is_file())
        self.assertTrue((ROOT / "scripts/node_deploy/run_stage.sh").is_file())


if __name__ == "__main__":
    unittest.main()
