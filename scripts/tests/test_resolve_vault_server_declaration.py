import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "node_deploy" / "resolve_vault_server_declaration.py"
SPEC = importlib.util.spec_from_file_location("resolve_vault_server_declaration", SCRIPT)
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(module)


def fixture():
    service = {
        "kind": "VaultServerDeployment",
        "metadata": {"environment": "shared"},
        "spec": {
            "service_domain": "vault.svc.plus",
            "access": {"bootstrap": "bootstrap-public", "steady_state": "xconnect-zero", "xconnect_topology": "vpn-overlay/shared/xconnect-vault-shared.yaml"},
            "automation": {
                "github_environment": "prod",
                "vault_addr": "https://vault.svc.plus",
                "runtime_identity_path": "kv/data/shared/platform/oidc/open-platform-prod",
                "monitoring_secret_path": "kv/data/CICD/observability",
                "xconnect_secret_path": "kv/data/CICD/shared/xconnect",
                "node_role": "github-actions-platform-ops-toolkit-shared-vault-node-oidc-open-platform-prod",
                "monitoring_role": "github-actions-platform-ops-toolkit-shared-vault-monitoring",
                "xconnect_role": "github-actions-platform-ops-toolkit-shared-vault-xconnect",
            },
        },
    }
    provider = {
        "kind": "GCPWorkloadNamespace",
        "metadata": {"environment": "shared"},
        "spec": {"gcp_account_id": "open-platform-prod", "project_id": "open-platform-prod",
                 "network_name": "vault-shared", "ssh_access_mode": "bootstrap-public"},
    }
    return service, provider


class VaultServerDeclarationTests(unittest.TestCase):
    def test_resolves_scoped_non_secret_adapter_inputs(self):
        service, provider = fixture()
        values = module.resolve(service, provider, "gcp-cloud")
        self.assertEqual(values["project_id"], "open-platform-prod")
        self.assertEqual(values["environment"], "shared")
        self.assertEqual(values["ssh_access_mode"], "bootstrap-public")

    def test_rejects_cross_environment_or_unsafe_paths(self):
        service, provider = fixture()
        provider["metadata"]["environment"] = "uat"
        with self.assertRaisesRegex(ValueError, "another environment"):
            module.resolve(service, provider, "gcp-cloud")
        provider["metadata"]["environment"] = "shared"
        service["spec"]["automation"]["runtime_identity_path"] = "kv/data/uat/platform/oidc/other"
        with self.assertRaisesRegex(ValueError, "must match"):
            module.resolve(service, provider, "gcp-cloud")
        with self.assertRaisesRegex(ValueError, "relative"):
            module.checked_path(Path("/tmp"), "../outside.yaml")


if __name__ == "__main__":
    unittest.main()
