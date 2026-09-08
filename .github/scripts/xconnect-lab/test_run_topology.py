"""Exercise real shell preflight, jq policy and Python window resolution offline."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


def declaration():
    return {
        'kind': 'XConnectLabTopology', 'metadata': {'environment': 'uat'},
        'spec': {
            'iac_module': 'vpn-overlay/xconnect-lab',
            'environment_reuse': 'uat-control-plane-vault-account-and-network',
            'gateway_provider': 'aws-spot',
            'compute_policy': 'all-cloud-compute-is-aws-spot-by-default',
            'ttl_minutes': 120,
            'node_observation': {'mode': 'until-expiry', 'release_on_failure': True},
            'zero': {
                'accounts_api_url': 'https://accounts-uat.onwalk.net',
                'portal_url': 'https://console-cloudflare-uat.onwalk.net/panel/xconnect-zero',
                'source_of_truth': 'formal-accounts-api-and-portal',
                'lab_controller': {'enabled': False, 'is_formal_config_source': False},
            },
            'artifacts': {
                'one': {'repository': 'ai-workspace-xstream/XConnect-One',
                        'asset': 'xconnect-linux-arm64', 'release_tag': 'v0.1.8'},
                'gateway': {'repository': 'ai-workspace-xstream/XConnect-Gateway',
                            'asset': 'xconnect-gateway-linux-arm64', 'release_tag': 'v0.1.4'},
                'xray': {'repository': 'XTLS/Xray-core',
                         'asset': 'Xray-linux-arm64-v8a.zip', 'release_tag': 'v26.3.27'},
            },
            'nodes': {
                'gateway': {
                    'product': 'XConnect One Gateway', 'role': 'relay',
                    'service_role': 'relay/service',
                    'baseline': 'independent-linux-node-external-wireguard-xray',
                    'architecture': 'arm64', 'instance_type': 't4g.small',
                    'vcpu': 2, 'memory_gib': 2, 'purchase_model': 'spot',
                    'max_runtime_minutes': 120,
                },
                'one': {
                    'product': 'XConnect One Linux client CLI', 'role': 'controlled-client',
                    'baseline': 'independent-linux-node-external-wireguard-xray',
                    'architecture': 'arm64', 'instance_type': 't4g.micro',
                    'vcpu': 2, 'memory_gib': 1, 'purchase_model': 'spot',
                    'max_runtime_minutes': 120,
                },
            },
            'desktop_validation': {
                'enabled': False, 'ingress_cidrs': [], 'platforms': ['darwin', 'windows'],
                'max_join_window_minutes': 20, 'transport': 'vless-tls-xudp',
                'public_wireguard_ingress': False,
                'acceptance': ['formal-invite', 'signed-sync-ack', 'owned-runtime',
                               'exact-peer-handshake', 'private-ping', 'exact-run-http-marker'],
            },
            'aws': {'reuse_default_vpc': True, 'reuse_default_subnet': True,
                    'ami_ssm_parameter': '/test/arm64/ami-id', 'region': 'ap-northeast-1',
                    'role_arn': 'arn:aws:iam::123456789012:role/test'},
            'vault': {'address': 'https://vault.svc.plus',
                      'role': 'github-actions-platform-ops-toolkit-uat-xconnect-cloud-lab',
                      'infrastructure_path': 'kv/data/CICD/uat',
                      'runtime_path': 'kv/data/uat/xconnect-one',
                      'github_app_path': 'kv/data/CICD/github-app/daily-snapshot'},
            'overlay': {'transport': 'vless-tls-xudp', 'gateway_address': '10.77.0.1/32',
                        'device_address': '10.77.0.2/32', 'public_wireguard_ingress': False,
                        'private_checks': ['ping', 'http', 'wireguard-handshake', 'config-sync']},
        },
    }


class ShellTopologyContract(unittest.TestCase):
    def preflight(self, value, mode='apply', window='auto', desktop='0', refs=None):
        with tempfile.TemporaryDirectory(prefix='xconnect-preflight-test-') as tmp:
            root = Path(tmp)
            scripts = root / '.github/scripts/xconnect-lab'
            scripts.mkdir(parents=True)
            for name in ('prepare.py', 'validate-topology.jq'):
                shutil.copyfile(SCRIPTS / name, scripts / name)
            target = root / 'gitops/vpn-overlay/uat/xconnect-lab.json'
            target.parent.mkdir(parents=True)
            target.write_text(json.dumps(value))
            env = {'PATH': os.environ['PATH'], 'GITHUB_WORKSPACE': str(root),
                   'LAB_DIR': str(root / 'lab'), 'GITHUB_OUTPUT': str(root / 'output'),
                   'GITHUB_ENV': str(root / 'env'), 'MODE': mode,
                   'IAC_REF': 'a' * 40, 'GITOPS_REF': 'b' * 40,
                   'CLI_RELEASE_TAG': 'v0.1.8', 'GATEWAY_RELEASE_TAG': 'v0.1.4',
                   'XRAY_RELEASE_TAG': 'v26.3.27', 'NODE_OBSERVATION_INPUT': window,
                   'DESKTOP_JOIN_WINDOW_MINUTES': desktop, 'MAC_JOIN_WINDOW_MINUTES': '0',
                   'CLEANUP_RUN': 'xcl-123456789-1' if mode == 'cleanup' else ''}
            env.update(refs or {})
            for stage in ('validate', 'topology'):
                result = subprocess.run(['bash', str(SCRIPTS / 'run.sh'), stage],
                                        env=env, capture_output=True, text=True, timeout=10)
                if result.returncode:
                    return result.returncode, result.stdout + result.stderr, ''
            return 0, (root / 'output').read_text(), (root / 'env').read_text()

    def test_apply_auto_retains_to_absolute_expiry(self):
        code, output, env = self.preflight(declaration())
        self.assertEqual(code, 0, output)
        self.assertIn('node_observation_window_minutes=until-expiry\n', output)
        self.assertIn('NODE_OBSERVATION_WINDOW_MINUTES=until-expiry\n', env)

    def test_explicit_windows_and_dry_run(self):
        for mode, window, expected in [('apply', '0', '0'), ('apply', '10', '10'),
                                       ('apply', '20', '20'), ('dry-run', 'auto', '0')]:
            with self.subTest(mode=mode, window=window):
                code, output, env = self.preflight(declaration(), mode, window)
                self.assertEqual(code, 0, output)
                self.assertIn(f'NODE_OBSERVATION_WINDOW_MINUTES={expected}\n', env)

    def test_legacy_cleanup_does_not_renew_or_block(self):
        value = declaration()
        value['spec']['ttl_minutes'] = 60
        value['spec'].pop('node_observation')
        for node in value['spec']['nodes'].values():
            node['max_runtime_minutes'] = 60
        code, output, env = self.preflight(value, mode='cleanup')
        self.assertEqual(code, 0, output)
        self.assertIn('NODE_OBSERVATION_WINDOW_MINUTES=0\n', env)
        self.assertNotEqual(self.preflight(value)[0], 0)

    def test_existing_scoped_desktop_stage_is_preserved(self):
        value = declaration()
        value['spec']['desktop_validation'].update(enabled=True, ingress_cidrs=['192.0.2.10/32'])
        code, output, env = self.preflight(value, desktop='20')
        self.assertEqual(code, 0, output)
        self.assertIn('NODE_OBSERVATION_WINDOW_MINUTES=0\n', env)
        self.assertNotEqual(self.preflight(value, desktop='20', window='until-expiry')[0], 0)
        value['spec']['desktop_validation']['ingress_cidrs'] = ['0.0.0.0/0']
        self.assertNotEqual(self.preflight(value, desktop='20')[0], 0)

    def test_all_original_uat_guards_remain_fail_closed(self):
        mutations = [
            (['kind'], 'OtherTopology'), (['metadata', 'environment'], 'prod'),
            (['spec', 'iac_module'], 'another/module'),
            (['spec', 'gateway_provider'], 'on-demand'),
            (['spec', 'nodes', 'gateway', 'instance_type'], 't4g.large'),
            (['spec', 'nodes', 'one', 'purchase_model'], 'on-demand'),
            (['spec', 'aws', 'reuse_default_vpc'], False),
            (['spec', 'zero', 'accounts_api_url'], 'https://untrusted.example'),
            (['spec', 'zero', 'lab_controller', 'enabled'], True),
            (['spec', 'vault', 'role'], 'production-admin'),
            (['spec', 'vault', 'runtime_path'], 'kv/data/prod/xconnect-one'),
            (['spec', 'node_observation', 'release_on_failure'], False),
            (['spec', 'overlay', 'transport'], 'plain-wireguard'),
            (['spec', 'overlay', 'public_wireguard_ingress'], True),
            (['spec', 'overlay', 'private_checks'], ['ping']),
            (['spec', 'artifacts', 'one', 'release_tag'], 'v0.1.7'),
        ]
        for path, changed in mutations:
            with self.subTest(path=path):
                value, cursor = declaration(), None
                cursor = value
                for part in path[:-1]:
                    cursor = cursor[part]
                cursor[path[-1]] = changed
                code, output, _ = self.preflight(value)
                self.assertNotEqual(code, 0, output)

    def test_invalid_input_never_enters_topology(self):
        for refs in [{'IAC_REF': 'main'}, {'GITOPS_REF': 'latest'}, {'CLI_RELEASE_TAG': 'main'}]:
            with self.subTest(refs=refs):
                self.assertNotEqual(self.preflight(declaration(), refs=refs)[0], 0)


if __name__ == '__main__':
    unittest.main()
