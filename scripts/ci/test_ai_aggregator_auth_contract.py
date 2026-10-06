"""Exercise auth migrations against the actual checked-out GitOps contract."""
import copy
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / 'scripts/ci/validate_ai_aggregator_manifest.py'
GITOPS = Path(os.environ.get('GITOPS_ROOT', ROOT / 'gitops'))


class AuthContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.paths = sorted((GITOPS / 'topology').glob('*/selfhost/ai-aggregator*.yaml'))
        if not cls.paths:
            raise RuntimeError(f'no AI Aggregator declarations under {GITOPS}')
        cls.base = yaml.safe_load(cls.paths[0].read_text())

    def check(self, data, valid):
        with tempfile.NamedTemporaryFile('w', suffix='.yaml') as candidate:
            yaml.safe_dump(data, candidate)
            candidate.flush()
            result = subprocess.run([sys.executable, str(VALIDATOR), candidate.name], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, valid, result.stderr)

    def test_all_environment_topologies(self):
        for path in self.paths:
            with self.subTest(path=path):
                self.check(yaml.safe_load(path.read_text()), True)

    def test_direct_mode_can_retain_dormant_adapter_for_rollback(self):
        data = copy.deepcopy(self.base)
        data['spec']['gateway']['entry_mode'] = 'direct-new-api'
        self.check(data, True)

    def test_environment_name_does_not_define_domain_or_lifecycle(self):
        data = copy.deepcopy(self.base)
        previous = data['metadata']['environment']
        domain = data['spec']['entrypoint']['domain']
        source = yaml.safe_dump(data).replace(
            f'vault://kv/{previous}/', 'vault://kv/preview-eu/'
        ).replace(domain, 'ai.preview.example.net')
        data = yaml.safe_load(source)
        data['metadata']['environment'] = 'preview-eu'
        self.check(data, True)

    def test_bootstrap_key_is_not_a_user_credential(self):
        data = copy.deepcopy(self.base)
        data['spec']['apisix']['runtime_secret_refs'] = {
            'AI_GATEWAY_CLIENT_KEY': f"vault://kv/{data['metadata']['environment']}/ai-aggregator/gateway/apisix#bootstrap_client_key"
        }
        self.check(data, False)

    def test_official_api_client_cannot_bypass_new_api_ledger(self):
        data = copy.deepcopy(self.base)
        client = next(p for p in data['spec']['client_profiles'] if p['id'] == 'android-studio')
        client['chain'] = 'litellm-direct'
        client['base_url'] = f"https://{data['spec']['entrypoint']['domain']}/litellm/v1"
        self.check(data, False)

    def test_public_litellm_route_cannot_bypass_new_api_ledger(self):
        data = copy.deepcopy(self.base)
        data['spec']['gateway']['routes']['litellm'] = {'path_prefix': '/litellm', 'upstream': 'litellm'}
        self.check(data, False)

    def test_gateway_consumer_cannot_replace_user_token_source(self):
        data = copy.deepcopy(self.base)
        data['spec']['client_profiles'][0]['token_source'] = 'kong'
        self.check(data, False)


if __name__ == '__main__':
    unittest.main()
