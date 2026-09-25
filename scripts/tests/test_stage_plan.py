import importlib.util
import json
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

    def test_names_are_grouped_by_path(self):
        for name in module.STAGES:
            stage = entry(name)
            if stage["path"] == "fresh":
                self.assertTrue(name.startswith("fresh-"), name)
            elif stage["path"] == "migration":
                self.assertTrue(name.startswith("migrate-"), name)
            else:
                self.assertTrue(name.startswith(("node-", "vault-", "xconnect-")), name)
        order = list(module.STAGES)
        groups = [entry(name)["path"] for name in order if entry(name)["enabled"]]
        # Each group is contiguous in the dropdown: any, then fresh, then migration.
        self.assertEqual(groups, sorted(groups, key=["any", "fresh", "migration"].index))

    def test_monitoring_comes_first_and_needs_only_access(self):
        order = list(module.STAGES)
        self.assertLess(order.index("node-process-metrics"), order.index("fresh-leader"))
        self.assertLess(order.index("node-process-metrics"), order.index("migrate-preflight"))
        self.assertEqual(entry("node-process-metrics")["requires"], ["access"])

    def test_migration_order_and_gates(self):
        order = list(module.STAGES)
        migration = ["migrate-auto", "migrate-preflight", "migrate-convert", "migrate-join", "migrate-cutover", "migrate-remove"]
        self.assertEqual(migration, sorted(migration, key=order.index))
        self.assertIn("legacy-overlay", entry("migrate-convert")["requires"])
        self.assertIn("vault-port-guard", entry("migrate-convert")["confirms"])
        self.assertEqual(entry("migrate-join")["requires"], ["access", "legacy-raft", "new-nodes-empty"])
        self.assertIn("raft-quorum", entry("migrate-cutover")["requires"])
        self.assertEqual(entry("migrate-cutover")["confirms"], ["legacy-standby"])
        self.assertIn("legacy-standby", entry("migrate-remove")["requires"])
        self.assertEqual(entry("migrate-remove")["confirms"], ["raft-quorum-new"])

    def test_host_changes_run_as_playbook_tags_not_toolkit_actions(self):
        self.assertEqual(entry("migrate-convert")["playbook"], module.LEGACY_PLAYBOOK)
        self.assertEqual(entry("migrate-convert")["tags"], ["vault-legacy-convert", "vault-single-raft"])
        self.assertEqual(entry("migrate-convert")["action"], "")
        self.assertEqual(entry("migrate-rollback")["tags"], ["vault-legacy-rollback"])
        self.assertEqual(entry("migrate-rollback")["action"], "")
        # Removal: Vault API action first, then the host-side retire tag.
        self.assertEqual(entry("migrate-remove")["action"], "remove-legacy")
        self.assertEqual(entry("migrate-remove")["tags"], ["vault-legacy-retire"])
        self.assertNotIn("legacy-convert", module.ACTIONS)
        self.assertNotIn("legacy-rollback", module.ACTIONS)

    def test_live_changes_need_the_exact_confirmation(self):
        for stage in ("migrate-auto", "migrate-convert", "migrate-rollback", "migrate-cutover", "migrate-remove"):
            phrase = entry(stage)["confirm"]
            self.assertTrue(phrase)
            with self.assertRaisesRegex(ValueError, "confirm="):
                module.plan(stage, "", migration=True)
            self.assertEqual(module.plan(stage, phrase, migration=True)["stage"], stage)

    def test_auto_mode_is_a_migration_stage_with_its_own_phrase(self):
        auto = entry("migrate-auto")
        self.assertTrue(auto["auto"])
        self.assertEqual(auto["confirm"], "MIGRATE-VAULT-AUTO")
        self.assertEqual(auto["ssh"], "all")
        self.assertEqual(auto["tags"], [])
        self.assertEqual(auto["action"], "")

    def test_paths_do_not_mix(self):
        with self.assertRaisesRegex(ValueError, "would initialize a new cluster"):
            module.plan("fresh-leader", migration=True)
        with self.assertRaisesRegex(ValueError, "spec.migration"):
            module.plan("migrate-join", migration=False)
        with self.assertRaisesRegex(ValueError, "spec.migration"):
            module.plan("migrate-auto", "MIGRATE-VAULT-AUTO", migration=False)
        module.plan("fresh-leader", migration=False)
        module.plan("vault-snapshot", migration=True)

    def test_manual_checkpoints_are_never_automated(self):
        for name in module.STAGES:
            stage = entry(name)
            self.assertNotIn("init", " ".join(stage["tags"]))
            self.assertNotIn("unseal", " ".join(stage["tags"]))
        self.assertIn("vault operator init", module.plan("fresh-leader")["next"])
        self.assertIn("list-peers", module.plan("migrate-join", migration=True)["next"])
        self.assertIn("Rekey", entry("migrate-remove")["next"])

    def test_unwired_or_unknown_stages_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "not available yet"):
            module.plan("xconnect-gateway")
        with self.assertRaisesRegex(ValueError, "unknown node stage"):
            module.plan("arbitrary-shell")

    def test_github_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "out"
            module.write_outputs(module.plan("migrate-cutover", "MOVE-VAULT-LEADER", True), output)
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(lines["stage"], "migrate-cutover")
        self.assertEqual(lines["action"], "cutover")
        self.assertEqual(lines["token"], "raft-operator")
        self.assertEqual(lines["ssh"], "all")
        self.assertEqual(lines["needs_observability"], "false")
        self.assertEqual(json.loads(lines["extra_vars"]), {"vault_legacy_migration_confirm": "MOVE-VAULT-LEADER"})

    def test_dispatch_options_match_enabled_stages(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/vault-server.yml").read_text(encoding="utf-8"))
        options = workflow[True]["workflow_dispatch"]["inputs"]["service_stage"]["options"]
        enabled = [name for name in module.STAGES if entry(name)["enabled"]]
        self.assertEqual(options, ["none", *enabled])


if __name__ == "__main__":
    unittest.main()
