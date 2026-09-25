import importlib.util
import stat
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


SCRIPT_DIR = Path(__file__).resolve().parents[1] / "node_deploy"
sys.path.insert(0, str(SCRIPT_DIR))
SPEC = importlib.util.spec_from_file_location("xconnect_stage", SCRIPT_DIR / "xconnect_stage.py")
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(module)

GATEWAY_KEY = "B" * 43 + "="
TOPOLOGY = {
    "apiVersion": "gitops.svc.plus/v1alpha1",
    "kind": "XConnectOneNodeSet",
    "metadata": {"name": "xconnect-vault-shared", "environment": "shared"},
    "spec": {
        "network": {
            "id": "net_shared_vault",
            "cidr": "10.79.0.0/24",
            "gateway_wireguard_address": "10.79.0.1/32",
            "transport_profile": {
                "kind": "vless-xhttp", "port": 443, "path": "/xconnect", "mode": "auto",
                "host": "vault-xconnect.svc.plus", "frontend": "caddy-unix-h2c",
                "listen_socket": "/run/xconnect-gateway/xray.sock",
            },
        },
        "control_plane": {"accounts_api_url": "https://accounts.svc.plus"},
        "runtime": {"gateway_state_dir": "/var/lib/xconnect-gateway/shared", "sync_interval_seconds": 300},
        "gateway": {"id": "vault-prod-0"},
    },
}
CONTRACT = {"spec": {"nodes": [
    {"id": "vault-prod-0", "groups": ["vault_shared_nodes", "vault_shared_leader", "xconnect_gateway"]},
    {"id": "vault-prod-1", "groups": ["vault_shared_nodes", "vault_shared_peers", "xconnect_one"]},
]}}
ENV = {"ZERO_SERVICE_TOKEN": "service-token", "ZERO_OWNER_EMAIL": "ops@example.com", "XCONNECT_VLESS_ID": "vless-id"}


def topology():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "topology.yaml"
        path.write_text(yaml.safe_dump(TOPOLOGY), encoding="utf-8")
        return module.load_topology(path)


def response(**overrides):
    body = {
        "network": {"id": "net_shared_vault"},
        "invite": {"network_id": "net_shared_vault", "device_id": "vault-prod-0", "role": "gateway",
                   "platform": "linux", "remaining_uses": 1},
        "join_uri": "xconnect://join/abc123",
    }
    body["invite"].update(overrides)
    return body


class TopologyTests(unittest.TestCase):
    def test_reads_the_gitops_declaration(self):
        declared = topology()
        self.assertEqual(declared["gateway_id"], "vault-prod-0")
        self.assertEqual(declared["transport_host"], "vault-xconnect.svc.plus")
        self.assertEqual(declared["controller"], "https://accounts.svc.plus")
        self.assertEqual(declared["frontend"], "caddy-unix-h2c")

    def test_rejects_a_non_https_controller(self):
        bad = yaml.safe_load(yaml.safe_dump(TOPOLOGY))
        bad["spec"]["control_plane"]["accounts_api_url"] = "http://accounts.svc.plus"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "topology.yaml"
            path.write_text(yaml.safe_dump(bad), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "https"):
                module.load_topology(path)


class InvitationTests(unittest.TestCase):
    def test_request_binds_the_gateway_key_and_device(self):
        body = module.bootstrap_request(topology(), "gateway", "vault-prod-0", GATEWAY_KEY, "ops@example.com",
                                        "vless-id", "2026-09-25T05:00:00Z")
        network = body["bootstrap"]["network"]
        self.assertEqual(network["gateway_wireguard_public_key"], GATEWAY_KEY)
        self.assertEqual(network["transport_server_name"], "vault-xconnect.svc.plus")
        self.assertEqual(network["gateway_id"], "vault-prod-0")
        self.assertEqual(body["bootstrap"]["invite"],
                         {"device_id": "vault-prod-0", "platform": "linux", "role": "gateway",
                          "expires_at": "2026-09-25T05:00:00Z"})

    def test_binding_mismatch_fails_closed(self):
        declared = topology()
        self.assertEqual(module.check_invite(response(), declared, "gateway", "vault-prod-0"), "xconnect://join/abc123")
        for override in ({"device_id": "vault-prod-1"}, {"role": "one"}, {"remaining_uses": 2}, {"network_id": "net_uat"}):
            with self.assertRaisesRegex(ValueError, "not bound"):
                module.check_invite(response(**override), declared, "gateway", "vault-prod-0")
        broken = response()
        broken["join_uri"] = "https://example.com"
        with self.assertRaisesRegex(ValueError, "join URI"):
            module.check_invite(broken, declared, "gateway", "vault-prod-0")

    def test_issued_invitation_is_a_private_file_and_never_returned(self):
        calls = []

        def post(url, token, body):
            calls.append((url, token, body))
            return 201, response()

        with tempfile.TemporaryDirectory() as directory:
            path = module.issue_invite(topology(), "gateway", "vault-prod-0", GATEWAY_KEY, Path(directory) / "s", ENV, post)
            self.assertEqual(path.read_text(), "xconnect://join/abc123\n")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(calls[0][0], "https://accounts.svc.plus/api/internal/overlay/networks/bootstrap")
        self.assertEqual(calls[0][1], "service-token")

    def test_http_errors_and_missing_secrets_stop_the_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "HTTP 409"):
                module.issue_invite(topology(), "gateway", "vault-prod-0", GATEWAY_KEY, Path(directory), ENV,
                                    lambda *_: (409, {}))
            with self.assertRaisesRegex(ValueError, "ZERO_SERVICE_TOKEN"):
                module.issue_invite(topology(), "gateway", "vault-prod-0", GATEWAY_KEY, Path(directory),
                                    {**ENV, "ZERO_SERVICE_TOKEN": ""}, lambda *_: (201, response()))


class VarsTests(unittest.TestCase):
    def test_gateway_vars_come_from_gitops_and_the_runner_private_dirs(self):
        values = module.gateway_vars(topology(), CONTRACT, Path("/r/bin"), Path("/r/secrets"), Path("/r/secrets/g.invite"))
        self.assertEqual(values["xconnect_gateway_id"], "vault-prod-0")
        self.assertEqual(values["xconnect_gateway_environment"], "shared")
        self.assertEqual(values["xconnect_gateway_binary_source"], "/r/bin/xconnect-gateway")
        self.assertEqual(values["xconnect_gateway_trust_bundle_source"], "/r/secrets/trust-bundle.pem")
        self.assertEqual(values["xconnect_gateway_invite_file_source"], "/r/secrets/g.invite")
        self.assertEqual(module.gateway_vars(topology(), CONTRACT, Path("/b"), Path("/s"), None)
                         ["xconnect_gateway_invite_file_source"], "")

    def test_contract_and_topology_must_name_the_same_gateway(self):
        other = {"spec": {"nodes": [{"id": "vault-prod-9", "groups": ["xconnect_gateway"]}]}}
        with self.assertRaisesRegex(ValueError, "not the topology Gateway"):
            module.gateway_vars(topology(), other, Path("/b"), Path("/s"), None)


class ArchitectureTests(unittest.TestCase):
    def test_one_architecture_for_all_targets(self):
        nodes = [{"id": "a"}, {"id": "b"}]
        self.assertEqual(module.architecture(nodes, {"a": {"machine": "x86_64"}, "b": {"machine": "amd64"}}), "amd64")
        with self.assertRaisesRegex(ValueError, "disagree"):
            module.architecture(nodes, {"a": {"machine": "x86_64"}, "b": {"machine": "aarch64"}})
        with self.assertRaisesRegex(ValueError, "unknown"):
            module.architecture(nodes, {"a": {}, "b": {"machine": "x86_64"}})


if __name__ == "__main__":
    unittest.main()
