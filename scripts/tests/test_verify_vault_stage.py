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
        {"id": "vault-0", "private_address": "10.81.0.2",
         "groups": ["vault_shared_nodes", "vault_shared_leader", "xconnect_gateway"]},
        {"id": "vault-1", "private_address": "10.81.0.3",
         "groups": ["vault_shared_nodes", "vault_shared_peers", "xconnect_one"]},
        {"id": "vault-2", "private_address": "10.81.0.4",
         "groups": ["vault_shared_nodes", "vault_shared_peers", "xconnect_one"]},
    ]
    contract = {"spec": {"nodes": nodes}}
    probes = {
        node["id"]: {
            "reachable": True,
            "sudo": True,
            "swap_kb": 0,
            "health": {"initialized": True, "sealed": False, "cluster_id": "cluster-a", "standby": index != 0},
            "leader": {"is_self": index == 0, "leader_cluster_address": "https://10.81.0.2:8201"},
            "units": {"vault": "active", "node-exporter": "active", "process-exporter": "active", "vector": "active"},
            "gateway_state": index == 0,
        }
        for index, node in enumerate(nodes)
    }
    return contract, probes


def fresh_install(probes):
    for state in probes.values():
        state["health"] = {"initialized": False, "sealed": True, "standby": True}
        state["leader"] = {"errors": ["Vault is sealed"]}


class VerifyVaultStageTests(unittest.TestCase):
    def test_access_requires_ssh_sudo_and_no_swap(self):
        contract, probes = fixture()
        module.verify(contract, ["access"], probes)
        probes["vault-1"]["swap_kb"] = 1024
        with self.assertRaisesRegex(ValueError, "swap"):
            module.verify(contract, ["access"], probes)
        probes["vault-1"]["swap_kb"] = 0
        probes["vault-2"] = {"reachable": False}
        with self.assertRaisesRegex(ValueError, "SSH probe failed"):
            module.verify(contract, ["access"], probes)

    def test_leader_stage_accepts_fresh_nodes_but_not_a_split_cluster(self):
        contract, probes = fixture()
        fresh_install(probes)
        module.verify(contract, ["access", "no-foreign-cluster"], probes)
        contract, probes = fixture()
        probes["vault-2"]["health"]["cluster_id"] = "cluster-b"
        with self.assertRaisesRegex(ValueError, "different Vault cluster IDs"):
            module.verify(contract, ["no-foreign-cluster"], probes)

    def test_peer_unsealed_before_leader_is_rejected(self):
        contract, probes = fixture()
        probes["vault-0"]["health"] = {"initialized": False, "sealed": True, "standby": True}
        with self.assertRaisesRegex(ValueError, "leader is uninitialized"):
            module.verify(contract, ["no-foreign-cluster"], probes)

    def test_peers_require_manually_unsealed_leader(self):
        contract, probes = fixture()
        fresh_install(probes)
        probes["vault-0"]["health"] = {"initialized": True, "sealed": False, "standby": False, "cluster_id": "c"}
        module.verify(contract, ["leader-unsealed"], probes)
        probes["vault-0"]["health"]["sealed"] = True
        with self.assertRaisesRegex(ValueError, "initialized and unsealed by an operator"):
            module.verify(contract, ["leader-unsealed"], probes)

    def test_running_checks_need_a_vault_listener_and_active_unit(self):
        contract, probes = fixture()
        fresh_install(probes)
        module.verify(contract, ["leader-running", "peers-running"], probes)
        probes["vault-1"]["health"] = None
        with self.assertRaisesRegex(ValueError, "vault-1: Vault is not answering"):
            module.verify(contract, ["peers-running"], probes)

    def test_raft_quorum_requires_one_cluster_one_leader_on_a_private_address(self):
        contract, probes = fixture()
        module.verify(contract, ["raft-quorum"], probes)
        probes["vault-2"]["health"]["cluster_id"] = "cluster-b"
        with self.assertRaisesRegex(ValueError, "not one Raft cluster"):
            module.verify(contract, ["raft-quorum"], probes)

    def test_raft_quorum_rejects_sealed_or_extra_active_nodes(self):
        contract, probes = fixture()
        probes["vault-1"]["health"]["sealed"] = True
        with self.assertRaisesRegex(ValueError, "manually unsealed"):
            module.verify(contract, ["raft-quorum"], probes)
        contract, probes = fixture()
        probes["vault-1"]["health"]["standby"] = False
        with self.assertRaisesRegex(ValueError, "exactly one active"):
            module.verify(contract, ["raft-quorum"], probes)

    def test_raft_quorum_rejects_a_leader_outside_the_declared_nodes(self):
        contract, probes = fixture()
        for state in probes.values():
            state["leader"]["leader_cluster_address"] = "https://10.9.9.9:8201"
        with self.assertRaisesRegex(ValueError, "not a declared node"):
            module.verify(contract, ["raft-quorum"], probes)
        contract, probes = fixture()
        probes["vault-2"]["leader"]["leader_cluster_address"] = "https://10.81.0.3:8201"
        with self.assertRaisesRegex(ValueError, "disagree"):
            module.verify(contract, ["raft-quorum"], probes)

    def test_monitoring_and_gateway_checks(self):
        contract, probes = fixture()
        module.verify(contract, ["monitoring-running", "gateway-enrolled"], probes)
        probes["vault-1"]["units"]["vector"] = "inactive"
        with self.assertRaisesRegex(ValueError, "vector"):
            module.verify(contract, ["monitoring-running"], probes)
        probes["vault-0"]["gateway_state"] = False
        with self.assertRaisesRegex(ValueError, "Gateway enrollment"):
            module.verify(contract, ["gateway-enrolled"], probes)

    def test_rejects_unknown_checks_and_reports_state(self):
        contract, probes = fixture()
        with self.assertRaisesRegex(ValueError, "unknown checks"):
            module.verify(contract, ["arbitrary-shell"], probes)
        report = module.summary(contract, probes, "Before test")
        self.assertIn("| vault-0 | active | cluster- |", report)
        self.assertIn("| vault-1 | standby |", report)


if __name__ == "__main__":
    unittest.main()
