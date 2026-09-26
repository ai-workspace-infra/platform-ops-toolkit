from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("manifest.py")


def declaration(environment: str = "prod") -> str:
    return f"""apiVersion: gitops.svc.plus/v1alpha1
kind: XConnectNetwork
metadata:
  name: vault-private
  environment: {environment}
spec:
  zero:
    accounts_api_url: https://accounts.svc.plus
    owner_email: ops@example.test
  network:
    id: net_shared_vault
    display_name: Shared Vault
    cidr: 10.90.0.0/24
  gateway:
    id: gw-vault-prod-0
    device_id: vault-prod-0
    wireguard_public_key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    wireguard_address: 10.90.0.1/32
    endpoint_host: vault.svc.plus
    endpoint_port: 51820
    transport:
      server_name: vault.svc.plus
      kind: vless-xhttp
      port: 443
      path: /xconnect
      mode: auto
"""


class ManifestContractTests(unittest.TestCase):
    def run_manifest(self, yaml_text: str, selected_environment: str = "prod") -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "gitops/vpn-overlay/networks/vault.yaml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(yaml_text, encoding="utf-8")
            output = root / "github-output"
            request = root / "private-request.json"
            environment = os.environ.copy()
            environment.update({
                "NETWORK_ENVIRONMENT": selected_environment,
                "NETWORK_MANIFEST": str(manifest),
                "VLESS_ID": "3c1ff11e-2d6b-1f6e-dcea-fd2c70b83e0b",
                "REQUEST_FILE": str(request),
                "GITHUB_OUTPUT": str(output),
            })
            # Use a relative in-repository path, just as the workflow does.
            environment["NETWORK_MANIFEST"] = "gitops/vpn-overlay/networks/vault.yaml"
            result = subprocess.run(["python3", str(SCRIPT)], cwd=root, env=environment, text=True, capture_output=True)
            result.request_json = json.loads(request.read_text()) if request.exists() else None  # type: ignore[attr-defined]
            result.output_text = output.read_text() if output.exists() else ""  # type: ignore[attr-defined]
            result.request_mode = request.stat().st_mode & 0o777 if request.exists() else None  # type: ignore[attr-defined]
            return result

    def test_valid_prod_declaration_builds_private_request(self) -> None:
        result = self.run_manifest(declaration())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("network_id=net_shared_vault", result.output_text)  # type: ignore[attr-defined]
        self.assertEqual(result.request_mode, 0o600)  # type: ignore[attr-defined]
        body = result.request_json  # type: ignore[attr-defined]
        self.assertEqual(body["bootstrap"]["network"]["id"], "net_shared_vault")
        self.assertEqual(body["bootstrap"]["network"]["transport_auth_id"], "3c1ff11e-2d6b-1f6e-dcea-fd2c70b83e0b")
        self.assertEqual(body["bootstrap"]["invite"]["role"], "gateway")
        self.assertNotIn("ops@example.test", result.stdout)

    def test_scope_mismatch_fails_closed(self) -> None:
        result = self.run_manifest(declaration("custom"), "prod")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match metadata.environment", result.stderr)

    def test_owner_must_come_from_gitops_not_legacy_vault_environment(self) -> None:
        result = self.run_manifest(declaration().replace("    owner_email: ops@example.test\n", ""))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("spec.zero.owner_email", result.stderr)

    def test_non_https_api_is_rejected(self) -> None:
        result = self.run_manifest(declaration().replace("https://accounts.svc.plus", "http://accounts.svc.plus"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be an HTTPS", result.stderr)

    def test_untrusted_api_domain_is_rejected(self) -> None:
        result = self.run_manifest(declaration().replace("https://accounts.svc.plus", "https://attacker.example"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("approved svc.plus or onwalk.net", result.stderr)

    def test_gateway_outside_network_is_rejected(self) -> None:
        result = self.run_manifest(declaration().replace("10.90.0.1/32", "10.91.0.1/32"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Gateway must belong", result.stderr)

    def test_manifest_path_escape_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = os.environ.copy()
            environment.update({
                "NETWORK_ENVIRONMENT": "prod",
                "NETWORK_MANIFEST": "gitops/vpn-overlay/networks/../../outside.yaml",
                "ZERO_OWNER_EMAIL": "ops@example.test",
                "VLESS_ID": "3c1ff11e-2d6b-1f6e-dcea-fd2c70b83e0b",
                "REQUEST_FILE": f"{temporary}/request.json",
                "GITHUB_OUTPUT": f"{temporary}/output",
            })
            result = subprocess.run(["python3", str(SCRIPT)], cwd=temporary, env=environment, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must resolve below", result.stderr)


if __name__ == "__main__":
    unittest.main()
