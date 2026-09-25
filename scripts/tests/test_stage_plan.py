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


class StagePlanTests(unittest.TestCase):
    def test_rollout_order_and_gates(self):
        self.assertEqual(
            list(module.STAGES),
            [
                "node-preflight",
                "vault-shared-leader",
                "vault-shared-peers",
                "vault-raft-verify",
                "node-process-metrics",
                "xconnect-gateway",
                "xconnect-one",
            ],
        )
        self.assertEqual(module.plan("vault-shared-peers")["requires"], ["access", "leader-unsealed"])
        for stage in ("vault-raft-verify", "node-process-metrics"):
            self.assertIn("raft-quorum", module.plan(stage)["requires"])
        self.assertEqual(module.plan("node-process-metrics")["secrets"], ["observability"])
        self.assertIn("gateway-enrolled", module.STAGES["xconnect-one"]["requires"])
        for entry in module.STAGES.values():
            self.assertTrue(set(entry["requires"]) | set(entry["confirms"]) <= module.CHECKS)
            self.assertIn("access", entry["requires"])

    def test_manual_checkpoints_are_never_automated(self):
        for entry in module.STAGES.values():
            self.assertNotIn("init", " ".join(entry["tags"]))
            self.assertNotIn("unseal", " ".join(entry["tags"]))
        self.assertIn("vault operator init", module.plan("vault-shared-leader")["next"])
        self.assertIn("list-peers", module.plan("vault-shared-peers")["next"])

    def test_unwired_or_unknown_stages_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "not available yet"):
            module.plan("xconnect-gateway")
        with self.assertRaisesRegex(ValueError, "unknown node stage"):
            module.plan("arbitrary-shell")

    def test_github_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "out"
            module.write_outputs(module.plan("node-process-metrics"), output)
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(lines["tags"], "node-process-metrics")
        self.assertEqual(lines["needs_observability"], "true")
        self.assertEqual(lines["requires"], "access,raft-quorum")

    def test_dispatch_options_match_enabled_stages(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/vault-server.yml").read_text(encoding="utf-8"))
        options = workflow[True]["workflow_dispatch"]["inputs"]["service_stage"]["options"]
        enabled = [name for name, entry in module.STAGES.items() if entry["enabled"]]
        self.assertEqual(options, ["none", *enabled])


if __name__ == "__main__":
    unittest.main()
