import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = ROOT / "scripts" / "node_deploy"
sys.path.insert(0, str(SCRIPT_DIR))
SPEC = importlib.util.spec_from_file_location("stage_plan", SCRIPT_DIR / "stage_plan.py")
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(module)


def entry(stage):
    return {**module.DEFAULTS, **module.STAGES[stage]}


class StagePlanTests(unittest.TestCase):
    def test_every_stage_is_well_formed(self):
        for name in module.STAGES:
            stage = entry(name)
            self.assertIn(stage["path"], {"any", "fresh", "migration"}, name)
            self.assertIn(stage["ssh"], {"new", "legacy", "all", "cluster", "none"}, name)
            self.assertTrue(set(stage["requires"]) | set(stage["confirms"]) <= module.CHECKS, name)
            self.assertIn(stage["action"], module.ACTIONS, name)
            self.assertIn(stage["token"], module.TOKENS, name)
            if stage["tags"]:
                self.assertTrue(stage["playbook"], name)
            if stage["ssh"] != "none":
                self.assertIn("access", stage["requires"], name)

    def test_monitoring_comes_first_and_needs_only_access(self):
        order = list(module.STAGES)
        self.assertLess(order.index("node-process-metrics"), order.index("vault-shared-leader"))
        self.assertLess(order.index("node-process-metrics"), order.index("legacy-preflight"))
        self.assertEqual(entry("node-process-metrics")["requires"], ["access"])

    def test_migration_order_and_gates(self):
        order = list(module.STAGES)
        migration = ["legacy-preflight", "legacy-convert-raft", "vault-snapshot", "vault-join-legacy", "vault-cutover", "vault-remove-legacy"]
        self.assertEqual(migration, sorted(migration, key=order.index))
        self.assertIn("legacy-overlay", entry("legacy-convert-raft")["requires"])
        self.assertIn("vault-port-guard", entry("legacy-convert-raft")["confirms"])
        self.assertEqual(entry("vault-join-legacy")["requires"], ["access", "legacy-raft", "new-nodes-empty"])
        self.assertIn("raft-quorum", entry("vault-cutover")["requires"])
        self.assertEqual(entry("vault-cutover")["confirms"], ["legacy-standby"])
        self.assertIn("legacy-standby", entry("vault-remove-legacy")["requires"])
        self.assertEqual(entry("vault-remove-legacy")["confirms"], ["raft-quorum-new"])

    def test_live_changes_need_the_exact_confirmation(self):
        for stage in ("legacy-convert-raft", "legacy-convert-rollback", "vault-cutover", "vault-remove-legacy"):
            phrase = entry(stage)["confirm"]
            self.assertTrue(phrase)
            with self.assertRaisesRegex(ValueError, "confirm="):
                module.plan(stage, "", migration=True)
            self.assertEqual(module.plan(stage, phrase, migration=True)["stage"], stage)

    def test_paths_do_not_mix(self):
        with self.assertRaisesRegex(ValueError, "would initialize a new cluster"):
            module.plan("vault-shared-leader", migration=True)
        with self.assertRaisesRegex(ValueError, "spec.migration"):
            module.plan("vault-join-legacy", migration=False)
        module.plan("vault-shared-leader", migration=False)
        module.plan("vault-snapshot", migration=True)

    def test_manual_checkpoints_are_never_automated(self):
        for name in module.STAGES:
            stage = entry(name)
            self.assertNotIn("init", " ".join(stage["tags"]))
            self.assertNotIn("unseal", " ".join(stage["tags"]))
        self.assertIn("vault operator init", module.plan("vault-shared-leader")["next"])
        self.assertIn("list-peers", module.plan("vault-join-legacy", migration=True)["next"])
        self.assertIn("Rekey", entry("vault-remove-legacy")["next"])

    def test_unwired_or_unknown_stages_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "not available yet"):
            module.plan("xconnect-gateway")
        with self.assertRaisesRegex(ValueError, "unknown node stage"):
            module.plan("arbitrary-shell")

    def test_github_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "out"
            module.write_outputs(module.plan("vault-cutover", "MOVE-VAULT-LEADER", True), output)
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(lines["action"], "cutover")
        self.assertEqual(lines["token"], "raft-operator")
        self.assertEqual(lines["ssh"], "all")
        self.assertEqual(lines["needs_observability"], "false")

    def test_dispatch_options_match_enabled_stages(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/vault-server.yml").read_text(encoding="utf-8"))
        options = workflow[True]["workflow_dispatch"]["inputs"]["service_stage"]["options"]
        enabled = [name for name in module.STAGES if entry(name)["enabled"]]
        self.assertEqual(options, ["none", *enabled])


if __name__ == "__main__":
    unittest.main()
