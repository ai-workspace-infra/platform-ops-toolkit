import importlib.util
import base64
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1] / "node_deploy"
sys.path.insert(0, str(SCRIPT_DIR))
SPEC = importlib.util.spec_from_file_location("resolve_gcp_vault", SCRIPT_DIR / "resolve_gcp_vault.py")
resolver = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(resolver)


def fixture():
    declared = [
        {"name": f"vault-prod-{index}", "zone": f"asia-east1-{chr(97 + index)}", "xconnect_role": "gateway" if index == 0 else "one", "public_ip": True}
        for index in range(3)
    ]
    host_key = base64.b64encode(b"\x00\x00\x00\x0bssh-ed25519" + b"\x00\x00\x00\x20" + b"0" * 32).decode()
    for node in declared:
        node["ssh_host_ed25519"] = host_key
    manifest = {
        "kind": "GCPWorkloadNamespace",
        "metadata": {"name": "vault-shared", "environment": "shared"},
        "spec": {"project_id": "open-platform-prod", "enable_oslogin": True, "enable_iap_ssh": False, "ssh_access_mode": "bootstrap-public", "ssh_source_ranges": ["35.79.83.48/32"], "resources": {"vault_nodes": declared}},
    }
    instances = [
        {"name": node["name"], "zone": node["zone"], "status": "RUNNING", "networkInterfaces": [{"networkIP": f"10.81.0.{index + 2}", "accessConfigs": [{"natIP": f"35.1.2.{index + 3}"}]}]}
        for index, node in enumerate(declared)
    ]
    service = {
        "kind": "VaultServerDeployment",
        "metadata": {"environment": "shared"},
        "spec": {
            "storage": {"backend": "raft", "address_scope": "private", "members": 3,
                        "leader": "vault-prod-0", "peers": ["vault-prod-1", "vault-prod-2"]},
            "nodes": [{"id": node["name"], "xconnect_role": node["xconnect_role"]} for node in declared],
            "stages": resolver.STAGES,
            "access": {"bootstrap": "bootstrap-public", "steady_state": "xconnect-zero",
                       "xconnect_topology": "vpn-overlay/shared/xconnect-vault-shared.yaml"},
        },
    }
    return manifest, service, instances


def raft_manifest():
    return {"spec": {"network_name": "vault-shared", "subnet_cidr": "10.81.0.0/20"}}


def raft_rule(ports=("8200", "8201"), sources=("10.81.0.0/20",), network="vault-shared", tags=("vault",), disabled=False):
    allowed = {"IPProtocol": "tcp"}
    if ports is not None:
        allowed["ports"] = list(ports)
    return {
        "name": "vault-shared-vault-raft-internal",
        "network": f"https://www.googleapis.com/compute/v1/projects/p/global/networks/{network}",
        "direction": "INGRESS",
        "disabled": disabled,
        "sourceRanges": list(sources),
        "targetTags": list(tags),
        "allowed": [allowed],
    }


class GcpVaultResolutionTests(unittest.TestCase):
    def test_resolves_public_ssh_and_private_raft_addresses(self):
        manifest, service, instances = fixture()
        result = resolver.resolve(manifest, service, instances, "open-platform-prod", "shared", "gha_1234567890")
        self.assertEqual(result["spec"]["nodes"][0]["address"], "35.1.2.3")
        self.assertEqual(result["spec"]["nodes"][0]["private_address"], "10.81.0.2")
        self.assertIn("vault_shared_leader", result["spec"]["nodes"][0]["groups"])
        self.assertIn("xconnect_one", result["spec"]["nodes"][1]["groups"])

    def test_rejects_wrong_project_or_missing_vm(self):
        manifest, service, instances = fixture()
        with self.assertRaises(ValueError):
            resolver.resolve(manifest, service, instances, "other-project", "shared", "gha_1234567890")
        with self.assertRaises(ValueError):
            resolver.resolve(manifest, service, instances[:2], "open-platform-prod", "shared", "gha_1234567890")

    def test_zero_trust_requires_assigned_overlay_ip_and_internal_dns(self):
        manifest, service, instances = fixture()
        manifest["spec"]["ssh_access_mode"] = "xconnect-zero"
        manifest["spec"]["ssh_source_ranges"] = []
        topology = {
            "kind": "XConnectOneNodeSet",
            "metadata": {"environment": "shared"},
            "spec": {
                "network": {"id": "net_shared_vault", "cidr": "10.79.0.0/24"},
                "control_plane": {"network_id": "net_shared_vault"},
                "gateway": {"id": "vault-prod-0", "xconnect": {"overlay_ip": "10.79.0.1", "internal_dns": "vault-prod-0.shared.internal"}},
                "fixed_nodes": [
                    {"id": "vault-prod-1", "xconnect": {"overlay_ip": "10.79.0.3", "internal_dns": "vault-prod-1.shared.internal"}},
                    {"id": "vault-prod-2", "xconnect": {"overlay_ip": "10.79.0.4", "internal_dns": "vault-prod-2.shared.internal"}},
                ],
            },
        }
        result = resolver.resolve(manifest, service, instances, "open-platform-prod", "shared", "gha_1234567890", topology)
        self.assertEqual(result["spec"]["nodes"][0]["address"], "vault-prod-0.shared.internal")
        self.assertEqual(result["spec"]["nodes"][0]["overlay_address"], "10.79.0.1")
        topology["spec"]["fixed_nodes"][0]["xconnect"].pop("internal_dns")
        with self.assertRaises(ValueError):
            resolver.resolve(manifest, service, instances, "open-platform-prod", "shared", "gha_1234567890", topology)

    def test_rejects_cross_environment_manifest_and_topology(self):
        manifest, service, instances = fixture()
        with self.assertRaisesRegex(ValueError, "environment"):
            resolver.resolve(manifest, service, instances, "open-platform-prod", "uat", "gha_1234567890")

    def test_migration_makes_every_new_node_a_peer_on_the_overlay(self):
        manifest, service, instances = fixture()
        service["spec"]["migration"] = {"raft_network": "overlay", "source": {"id": "legacy"}}
        topology = {
            "spec": {
                "network": {"cidr": "10.79.0.0/24"},
                "gateway": {"id": "vault-prod-0", "xconnect": {"overlay_ip": "10.79.0.1"}},
                "fixed_nodes": [
                    {"id": "vault-prod-1", "xconnect": {"overlay_ip": "10.79.0.3"}},
                    {"id": "vault-prod-2", "xconnect": {"overlay_ip": "10.79.0.4"}},
                ],
            },
        }
        result = resolver.resolve(manifest, service, instances, "open-platform-prod", "shared", "gha_1234567890", topology)
        for node in result["spec"]["nodes"]:
            self.assertIn("vault_shared_peers", node["groups"])
            self.assertNotIn("vault_shared_leader", node["groups"])
        self.assertNotIn("vault-shared-leader", result["spec"]["stages"])
        self.assertEqual(result["spec"]["nodes"][0]["private_address"], "10.79.0.1")
        self.assertEqual(result["spec"]["nodes"][0]["address"], "35.1.2.3")
        topology["spec"]["fixed_nodes"][1]["xconnect"] = {}
        with self.assertRaisesRegex(ValueError, "no assigned XConnect overlay IP"):
            resolver.resolve(manifest, service, instances, "open-platform-prod", "shared", "gha_1234567890", topology)

    def test_contract_records_connection_mode(self):
        manifest, service, instances = fixture()
        result = resolver.resolve(manifest, service, instances, "open-platform-prod", "shared", "gha_1234567890")
        self.assertEqual(result["spec"]["connection"], {"mode": "bootstrap-public"})

    def test_private_raft_channel_matches_the_iac_rule(self):
        manifest = raft_manifest()
        resolver.verify_private_raft_channel(manifest, [raft_rule()])
        split = [raft_rule(ports=["8200"]), raft_rule(ports=["8201"])]
        resolver.verify_private_raft_channel(manifest, split)
        resolver.verify_private_raft_channel(manifest, [raft_rule(ports=["8200-8201"])])

    def test_private_raft_channel_must_exist_and_stay_private(self):
        manifest = raft_manifest()
        with self.assertRaisesRegex(ValueError, "8201"):
            resolver.verify_private_raft_channel(manifest, [raft_rule(ports=["8200"])])
        with self.assertRaisesRegex(ValueError, "no private Raft"):
            resolver.verify_private_raft_channel(manifest, [raft_rule(disabled=True)])
        with self.assertRaisesRegex(ValueError, "no private Raft"):
            resolver.verify_private_raft_channel(manifest, [raft_rule(network="other")])
        with self.assertRaisesRegex(ValueError, "no private Raft"):
            resolver.verify_private_raft_channel(manifest, [raft_rule(sources=["10.0.0.0/8"])])
        with self.assertRaisesRegex(ValueError, "exposes Vault port 8200 publicly"):
            resolver.verify_private_raft_channel(manifest, [raft_rule(), raft_rule(sources=["0.0.0.0/0"], ports=None)])
        public_all = raft_rule(sources=["0.0.0.0/0"])
        public_all["allowed"] = [{"IPProtocol": "all"}]
        with self.assertRaisesRegex(ValueError, "publicly"):
            resolver.verify_private_raft_channel(manifest, [raft_rule(), public_all])
        https = raft_rule(sources=["0.0.0.0/0"], ports=["443"], tags=["vault-gateway"])
        resolver.verify_private_raft_channel(manifest, [raft_rule(), https])

    def test_rejects_provider_nodes_that_differ_from_service_declaration(self):
        manifest, service, instances = fixture()
        manifest["spec"]["resources"]["vault_nodes"][1]["xconnect_role"] = "gateway"
        with self.assertRaisesRegex(ValueError, "provider-neutral"):
            resolver.resolve(manifest, service, instances, "open-platform-prod", "shared", "gha_1234567890")


if __name__ == "__main__":
    unittest.main()
