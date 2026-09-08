"""Cleanup boundary tests; no cloud calls or provisioning."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare', Path(__file__).with_name('prepare.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class CleanupBoundary(unittest.TestCase):
    def run_cleanup(self, root):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            declaration = folder / 'declaration.json'
            declaration.write_text(json.dumps({'spec': {'gateway_provider': 'aws-spot',
                'aws': {'region': 'ap-northeast-1'},
                'nodes': {'one': {'instance_type': 't4g.micro'},
                          'gateway': {'instance_type': 't4g.small'}},
                'zero': {'accounts_api_url': 'https://accounts-uat.onwalk.net',
                         'portal_url': 'https://console-uat.onwalk.net/panel/xconnect-zero'}}}))
            (folder / 'state.json').write_text(json.dumps({'values': {'root_module': root}}))
            with patch.dict(os.environ, {'TF_VAR_run_id': 'xcl-123-1'}), patch('sys.argv',
                    ['prepare', 'cleanup', directory, str(declaration)]):
                prepare.main()
            return json.loads((folder / 'variables.json').read_text())

    def test_empty_partial_state_can_be_cleaned(self):
        self.assertEqual(self.run_cleanup({})['run_id'], 'xcl-123-1')

    def test_owned_instances(self):
        self.run_cleanup({'resources': [
            {'address': 'aws_instance.client', 'type': 'aws_instance', 'values': {'tags_all': {'LabRun': 'xcl-123-1'}}},
            {'address': 'aws_instance.gateway', 'type': 'aws_instance', 'values': {'tags_all': {'LabRun': 'xcl-123-1'}}}]})

    def test_reused_network_data_is_not_destroyable_state(self):
        self.run_cleanup({'resources': [
            {'address': 'data.aws_vpc.uat', 'mode': 'data', 'type': 'aws_vpc', 'values': {'id': 'vpc-uat'}},
            {'address': 'data.aws_subnets.uat', 'mode': 'data', 'type': 'aws_subnets', 'values': {'ids': ['subnet-uat']}}]})

    def test_foreign_aws_refused(self):
        with self.assertRaises(ValueError):
            self.run_cleanup({'resources': [{'address': 'aws_instance.client', 'type': 'aws_instance',
                'values': {'tags_all': {'LabRun': 'xcl-999-1'}}}]})

    def test_unexpected_resource_refused(self):
        with self.assertRaises(ValueError):
            self.run_cleanup({'resources': [{'address': 'aws_instance.production', 'type': 'aws_instance', 'values': {}}]})

    def test_nested_module_refused(self):
        with self.assertRaises(ValueError):
            self.run_cleanup({'child_modules': [{'address': 'module.production'}]})


class DesktopContract(unittest.TestCase):
    def spec(self, enabled=True, cidrs=None, platforms=None):
        return {'desktop_validation': {
            'enabled': enabled,
            'ingress_cidrs': ['198.51.100.10/32'] if cidrs is None else cidrs,
            'platforms': ['darwin', 'windows'] if platforms is None else platforms,
            'max_join_window_minutes': 20,
            'transport': 'vless-tls-xudp',
            'public_wireguard_ingress': False,
        }}

    def test_linux_default_never_passes_ingress(self):
        self.assertEqual(prepare.validate_desktop_validation({}, 0), [])

    def test_allowed_windows_and_gitops_binding(self):
        self.assertEqual(prepare.validate_desktop_validation(self.spec(), 10), ['198.51.100.10/32'])
        self.assertEqual(prepare.validate_desktop_validation(self.spec(cidrs=['198.51.100.10/32', '203.0.113.20/32']), 20),
                         ['198.51.100.10/32', '203.0.113.20/32'])

    def test_window_bounds_and_apply_contract(self):
        for window in (-1, 5, 15, 21):
            with self.assertRaises(ValueError):
                prepare.validate_desktop_validation(self.spec(), window)
        with self.assertRaises(ValueError):
            prepare.validate_desktop_validation(self.spec(enabled=False), 10)
        invalid_spec = self.spec()
        invalid_spec['desktop_validation']['max_join_window_minutes'] = 10
        with self.assertRaises(ValueError):
            prepare.validate_desktop_validation(invalid_spec, 10)
        invalid_spec = self.spec()
        invalid_spec['desktop_validation']['public_wireguard_ingress'] = True
        with self.assertRaises(ValueError):
            prepare.validate_desktop_validation(invalid_spec, 10)

    def test_observation_windows_are_bounded_and_mutually_exclusive(self):
        for window in (0, 10, 20):
            prepare.validate_observation_windows(window, 0)
            prepare.validate_observation_windows(0, window)
        with self.assertRaises(ValueError):
            prepare.validate_observation_windows(10, 20)
        with self.assertRaises(ValueError):
            prepare.validate_observation_windows(5, 0)

    def test_ingress_and_platform_contract(self):
        invalid = [
            ['198.51.100.10/24'],
            ['2001:db8::10/128'],
            ['198.51.100.10/32', '198.51.100.10/32'],
            ['198.51.100.10/32', '203.0.113.20/32', '192.0.2.30/32'],
            [' 198.51.100.10/32'],
        ]
        for cidrs in invalid:
            with self.assertRaises(ValueError):
                prepare.validate_desktop_validation(self.spec(cidrs=cidrs), 10)
        with self.assertRaises(ValueError):
            prepare.validate_desktop_validation(self.spec(platforms=['windows', 'darwin']), 10)


class SSHDebugContract(unittest.TestCase):
    def test_empty_debug_allowlist_is_closed(self):
        self.assertEqual(prepare.validate_ssh_debug_access({}), [])

    def test_accepts_at_most_two_canonical_hosts(self):
        spec = {'debug_access': {'ssh_ingress_cidrs': ['35.79.83.48/32', '192.0.2.20/32']}}
        self.assertEqual(prepare.validate_ssh_debug_access(spec), ['35.79.83.48/32', '192.0.2.20/32'])

    def test_rejects_broad_or_malformed_debug_access(self):
        for cidrs in (['0.0.0.0/0'], ['35.79.83.48/24'], ['35.79.83.48/32', '35.79.83.48/32'],
                      ['35.79.83.48/32', '192.0.2.20/32', '198.51.100.30/32']):
            with self.subTest(cidrs=cidrs), self.assertRaises(ValueError):
                prepare.validate_ssh_debug_access({'debug_access': {'ssh_ingress_cidrs': cidrs}})

    def handoff(self):
        run = 'xcl-123-1'
        return {
            'run': run,
            'expires_at': '2030-01-01T00:00:00Z',
            'network_id': 'net_uat-xcl-123-1',
            'gateway_id': 'gw-xcl-123-1',
            'gateway_public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            'gateway_endpoint': {'host': '8.8.8.8', 'port': 443, 'server_name': 'xconnect-lab.invalid'},
            'accounts_url': 'https://accounts-uat.onwalk.net',
            'portal_url': 'https://console-cloudflare-uat.onwalk.net/panel/xconnect-zero',
            'instances': {
                'gateway': {'instance_id': 'i-abcdef123', 'public_ip': '8.8.8.8', 'private_ip': '10.0.0.10'},
                'linux_one': {'instance_id': 'i-0123abcd', 'public_ip': '1.1.1.1', 'private_ip': '10.0.0.20'},
            },
            'expected_device_ids': {'darwin': 'one-darwin-xcl-123-1', 'windows': 'one-windows-xcl-123-1'},
            'verification': {'target': 'http://10.77.0.1:8080/', 'expected_marker': run},
        }

    def test_public_handoff_strict_allowlist(self):
        handoff = self.handoff()
        self.assertTrue(prepare.validate_public_handoff(handoff))
        extra = dict(handoff)
        extra['invite'] = 'must-not-be-published'
        with self.assertRaises(ValueError):
            prepare.validate_public_handoff(extra)

    def test_public_handoff_identity_binding(self):
        for path in (('expected_device_ids', 'darwin'), ('verification', 'expected_marker')):
            handoff = self.handoff()
            handoff[path[0]][path[1]] = 'wrong'
            with self.assertRaises(ValueError):
                prepare.validate_public_handoff(handoff)
        handoff = self.handoff()
        handoff['gateway_id'] = 'gw-other'
        with self.assertRaises(ValueError):
            prepare.validate_public_handoff(handoff)

    def test_public_handoff_metadata_is_not_arbitrary(self):
        cases = [
            ('accounts_url', 'https://attacker.example'),
            ('portal_url', 'https://console-cloudflare-uat.onwalk.net/secret'),
            ('gateway_endpoint', {'host': 'gateway.example', 'port': 443, 'server_name': 'xconnect-lab.invalid'}),
        ]
        for key, value in cases:
            handoff = self.handoff()
            handoff[key] = value
            with self.assertRaises(ValueError):
                prepare.validate_public_handoff(handoff)
        handoff = self.handoff()
        handoff['instances']['gateway']['instance_id'] = 'i-not-hex'
        with self.assertRaises(ValueError):
            prepare.validate_public_handoff(handoff)

    def test_node_handoff_may_bind_to_private_gateway_endpoint(self):
        handoff = self.handoff()
        handoff['gateway_endpoint']['host'] = handoff['instances']['gateway']['private_ip']
        self.assertTrue(prepare.validate_public_handoff(handoff))


class NodeObservationContract(unittest.TestCase):
    def spec(self, ttl=60, observation=None):
        value = {'ttl_minutes': ttl}
        if observation is not None:
            value['node_observation'] = observation
        return value

    def test_auto_follows_until_expiry_declaration(self):
        spec = self.spec(60, {'mode': 'until-expiry', 'release_on_failure': True})
        self.assertEqual(prepare.resolve_node_observation(spec, 'auto', 'apply'), 'until-expiry')
        for window in ('0', '10', '20', 'until-expiry'):
            with self.subTest(window=window):
                self.assertEqual(prepare.resolve_node_observation(spec, window, 'apply'), window)

    def test_desktop_window_forces_auto_node_window_to_zero(self):
        spec = self.spec(60, {'mode': 'until-expiry', 'release_on_failure': True})
        self.assertEqual(prepare.resolve_node_observation(spec, 'auto', 'apply', 20), '0')

    def test_cleanup_and_dry_run_resolve_to_zero(self):
        spec = self.spec(60, {'mode': 'until-expiry', 'release_on_failure': True})
        self.assertEqual(prepare.resolve_node_observation(spec, 'until-expiry', 'cleanup'), '0')
        self.assertEqual(prepare.resolve_node_observation(spec, 'auto', 'dry-run'), '0')

    def test_new_lease_requires_declaration_and_release_on_failure(self):
        for observation in (None, {'mode': 'until-expiry', 'release_on_failure': False}):
            with self.subTest(observation=observation), self.assertRaises(ValueError):
                prepare.resolve_node_observation(self.spec(60, observation), 'auto', 'apply')

    def test_old_declaration_auto_is_compatible(self):
        self.assertEqual(prepare.resolve_node_observation(self.spec(60), 'auto', 'cleanup'), '0')
        self.assertEqual(prepare.resolve_node_observation(self.spec(120), 'auto', 'cleanup'), '0')
        with self.assertRaises(ValueError):
            prepare.resolve_node_observation(self.spec(120, {'mode': 'until-expiry', 'release_on_failure': True}), 'auto', 'apply')

    def test_invalid_window_is_rejected(self):
        with self.assertRaises(ValueError):
            prepare.resolve_node_observation(self.spec(60, {'mode': 'until-expiry', 'release_on_failure': True}), '30', 'apply')


if __name__ == '__main__':
    unittest.main()
