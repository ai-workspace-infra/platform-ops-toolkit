import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1] / "node_deploy"
sys.path.insert(0, str(SCRIPT_DIR))
SPEC = importlib.util.spec_from_file_location("verify_vault_stage", SCRIPT_DIR / "verify_vault_stage.py")
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(module)


def fixture():
    nodes = [
        {"id": "vault-0", "groups": ["vault_shared_nodes", "vault_shared_leader"]},
        {"id": "vault-1", "groups": ["vault_shared_nodes", "vault_shared_peers"]},
        {"id": "vault-2", "groups": ["vault_shared_nodes", "vault_shared_peers"]},
    ]
    contract = {"spec": {"nodes": nodes}}
    health = {
        node["id"]: {"initialized": True, "sealed": False, "cluster_id": "cluster-a", "standby": index != 0}
        for index, node in enumerate(nodes)
    }
    return contract, health


class VerifyVaultStageTests(unittest.TestCase):
    def test_peers_require_manually_unsealed_leader(self):
        contract, health = fixture()
        module.verify(contract, "vault-shared-peers", {"vault-0": health["vault-0"]})
        health["vault-0"]["sealed"] = True
        with self.assertRaisesRegex(ValueError, "manually initialized and unsealed"):
            module.verify(contract, "vault-shared-peers", {"vault-0": health["vault-0"]})

    def test_later_stages_require_one_healthy_cluster(self):
        contract, health = fixture()
        for stage in ("node-process-metrics", "xconnect-gateway", "xconnect-one"):
            module.verify(contract, stage, health)
        health["vault-2"]["cluster_id"] = "cluster-b"
        with self.assertRaisesRegex(ValueError, "one cluster"):
            module.verify(contract, "node-process-metrics", health)

    def test_later_stages_reject_unsealed_or_extra_active_node(self):
        contract, health = fixture()
        health["vault-1"]["sealed"] = True
        with self.assertRaisesRegex(ValueError, "manually unsealed"):
            module.verify(contract, "xconnect-one", health)
        health["vault-1"]["sealed"] = False
        health["vault-1"]["standby"] = False
        with self.assertRaisesRegex(ValueError, "one active and two standby"):
            module.verify(contract, "xconnect-one", health)


if __name__ == "__main__":
    unittest.main()
