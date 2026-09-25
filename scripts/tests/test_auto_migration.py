import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1] / "node_deploy"
sys.path.insert(0, str(SCRIPT_DIR))
SPEC = importlib.util.spec_from_file_location("auto_migration", SCRIPT_DIR / "auto_migration.py")
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(module)


NEW = ("vault-0", "vault-1", "vault-2")


def contract():
    nodes = [
        {"id": node_id, "private_address": f"10.79.0.{index + 1}", "address": f"35.1.2.{index}",
         "groups": ["vault_shared_nodes", "vault_shared_peers"]}
        for index, node_id in enumerate(NEW)
    ]
    nodes.append({
        "id": "legacy", "address": "jp.example.net", "private_address": "10.79.0.10", "overlay_address": "10.79.0.10",
        "groups": ["vault_legacy_source", "vault_shared_leader", "vault_single_node"],
    })
    return {"spec": {"nodes": nodes}}


def running(storage, initialized=True, sealed=False, standby=False):
    return {
        "reachable": True,
        "storage_type": storage,
        "health": {"initialized": initialized, "sealed": sealed, "standby": standby, "cluster_id": "c"},
        "units": {"vault": "active"},
        "vault_enabled": "enabled",
    }


def empty():
    return {"reachable": True, "health": None, "units": {"vault": "inactive"}, "vault_enabled": "disabled"}


def probes(legacy, new=None):
    states = {node_id: (new or {}).get(node_id, empty()) for node_id in NEW}
    states["legacy"] = legacy
    return states


OBSERVED = {"dns_switched_at": "2020-01-01T00:00:00+00:00", "hours": 24}


def decide(states, dns_on_legacy=True, backup=True, observation=None):
    return module.decide(
        contract(), states, dns_on_legacy=dns_on_legacy, backup_declared=backup,
        observation=OBSERVED if observation is None else observation,
    )


class AutoMigrationDecisionTests(unittest.TestCase):
    def test_postgresql_source_is_converted_only_when_unsealed(self):
        self.assertEqual(decide(probes(running("postgresql")))["stage"], "migrate-convert")
        result = decide(probes(running("postgresql", sealed=True)))
        self.assertEqual(result["stage"], "")
        self.assertIn("unseal the existing PostgreSQL-backed Vault", result["blocked"])

    def test_converted_source_must_be_unsealed_by_hand(self):
        result = decide(probes(running("raft", sealed=True)))
        self.assertEqual(result["stage"], "")
        self.assertIn("unseal the converted node", result["blocked"])

    def test_join_takes_a_snapshot_first_and_requires_a_declared_backup(self):
        result = decide(probes(running("raft")))
        self.assertEqual(result, {"stage": "migrate-join", "blocked": ""})
        self.assertTrue(module.plan("migrate-join", migration=True)["snapshot_first"])
        result = decide(probes(running("raft")), backup=False)
        self.assertEqual(result["stage"], "")
        self.assertIn("spec.backup", result["blocked"])

    def test_joined_but_sealed_nodes_stop_for_manual_unseal_and_list_peers(self):
        new = {"vault-0": running("raft", sealed=True), "vault-1": running("raft", sealed=True), "vault-2": running("raft", standby=True)}
        result = decide(probes(running("raft"), new))
        self.assertEqual(result["stage"], "")
        self.assertIn("vault-0, vault-1", result["blocked"])
        self.assertIn("raft list-peers", result["blocked"])

    def test_nodes_join_one_at_a_time_after_each_manual_unseal(self):
        # vault-0 joined and was unsealed by hand: the next join is chosen.
        new = {"vault-0": running("raft", standby=True)}
        self.assertEqual(decide(probes(running("raft"), new))["stage"], "migrate-join")
        # vault-1 joined but is still sealed: stop until an operator unseals it.
        new["vault-1"] = running("raft", sealed=True)
        result = decide(probes(running("raft"), new))
        self.assertEqual(result["stage"], "")
        self.assertIn("Unseal vault-1", result["blocked"])

    def test_cutover_when_every_node_is_unsealed_and_the_source_still_leads(self):
        new = {node_id: running("raft", standby=True) for node_id in NEW}
        self.assertEqual(decide(probes(running("raft"), new))["stage"], "migrate-cutover")

    def test_removal_waits_for_the_dns_move_and_the_observation_window(self):
        new = {node_id: running("raft", standby=node_id != "vault-1") for node_id in NEW}
        source = running("raft", standby=True)
        result = decide(probes(source, new), dns_on_legacy=True)
        self.assertEqual(result["stage"], "")
        self.assertIn("Switch the service DNS", result["blocked"])
        self.assertIn("dns_switched_at", result["blocked"])
        result = decide(probes(source, new), dns_on_legacy=False, observation={})
        self.assertEqual(result["stage"], "")
        self.assertIn("Observing", result["blocked"])
        result = decide(probes(source, new), dns_on_legacy=False, observation={"dns_switched_at": "2999-01-01T00:00:00Z"})
        self.assertIn("observation window runs until", result["blocked"])
        self.assertEqual(decide(probes(source, new), dns_on_legacy=False)["stage"], "migrate-remove")

    def test_retired_source_with_an_active_new_leader_is_done(self):
        new = {node_id: running("raft", standby=node_id != "vault-1") for node_id in NEW}
        result = decide(probes(empty(), new))
        self.assertEqual(result["stage"], "")
        self.assertIn("Migration complete", result["blocked"])
        self.assertIn("rekey", result["blocked"])
        result = decide(probes(empty()))
        self.assertIn("no new node is active", result["blocked"])

    def test_unreachable_or_stopped_source_stops_the_automation(self):
        self.assertIn("unreachable", decide(probes({"reachable": False}))["blocked"])
        stopped = {"reachable": True, "health": None, "units": {"vault": "failed"}, "vault_enabled": "enabled"}
        self.assertIn("not answering", decide(probes(stopped))["blocked"])

    def test_rollback_is_never_chosen(self):
        states = [
            probes(running("postgresql")), probes(running("raft")), probes(running("raft", sealed=True)),
            probes(running("raft", standby=True), {node_id: running("raft") for node_id in NEW}),
        ]
        for state in states:
            for dns in (True, False):
                self.assertNotEqual(decide(state, dns_on_legacy=dns)["stage"], "migrate-rollback")


class DnsCheckTests(unittest.TestCase):
    def test_unresolvable_service_name_counts_as_still_on_the_old_node(self):
        verify = sys.modules["verify_vault_stage"]
        original = verify.addresses
        try:
            verify.addresses = lambda host: {"service.example": set(), "old.example": {"46.0.0.1"}}.get(host, set())
            self.assertTrue(module.dns_points_at_legacy("service.example", "old.example"))
            verify.addresses = lambda host: {"service.example": {"34.1.1.1"}, "old.example": {"46.0.0.1"}}[host]
            self.assertFalse(module.dns_points_at_legacy("service.example", "old.example"))
            verify.addresses = lambda host: {"service.example": {"46.0.0.1"}, "old.example": {"46.0.0.1"}}[host]
            self.assertTrue(module.dns_points_at_legacy("service.example", "old.example"))
        finally:
            verify.addresses = original


class OutputTests(unittest.TestCase):
    def test_chosen_stage_outputs_carry_its_own_snapshot_and_one_node_flags(self):
        result = module.plan("migrate-join", "", migration=True)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "out"
            module.write_outputs(result, output, {"blocked": ""})
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(values["stage"], "migrate-join")
        self.assertEqual(values["tags"], "vault-shared-peers")
        # The snapshot uses the backup login's own token; join itself needs none.
        self.assertEqual(values["token"], "")
        self.assertEqual(values["snapshot_first"], "true")
        self.assertEqual(values["one_node"], "true")
        convert = module.plan("migrate-convert", module.STAGES["migrate-convert"]["confirm"], migration=True)
        self.assertEqual(convert["confirm"], "CONVERT-VAULT-TO-RAFT")


if __name__ == "__main__":
    unittest.main()
