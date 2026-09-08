"""Execute the remote observation fragments against local Gateway/One fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parent
KEY = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
RUN = 'xcl-123-1'
NETWORK = 'net_uat-xcl-123-1'
GATEWAY = 'gw-xcl-123-1'
CLIENT = 'one-xcl-123-1'


def fixture_command(directory, name, body):
    path = Path(directory) / name
    path.write_text(f'#!/usr/bin/env bash\nset -euo pipefail\n{body}\n')
    path.chmod(0o755)


class RemoteObservationFixture(unittest.TestCase):
    def env(self, directory):
        environment = os.environ.copy()
        environment['PATH'] = f'{directory}{os.pathsep}{environment["PATH"]}'
        return environment

    def test_gateway_fragment_checks_exact_applied_peer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'gateway'
            runtime = state / 'runtime'
            runtime.mkdir(parents=True)
            (state / 'state.json').write_text(json.dumps({
                'gateway_id': GATEWAY, 'network_id': NETWORK,
                'applied_generation': 2, 'applied_config_id': 'cfg-2',
            }))
            (runtime / 'xconzero0.conf').write_text(
                f'[Interface]\n\n# DeviceID = {CLIENT}\nPublicKey = {KEY}\n')
            fixture_command(root, 'xconnect-gateway', 'exit 0')
            fixture_command(root, 'wg', f'echo "{KEY} $(date +%s)"')
            result = subprocess.run(
                ['bash', str(ROOT / 'remote-gateway-observation.sh'), RUN, GATEWAY, NETWORK, CLIENT],
                env={**self.env(root), 'XCONNECT_GATEWAY_STATE_DIR': str(state)},
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('refresh=OK', result.stdout)
            self.assertIn('gateway_peer=OBSERVED', result.stdout)
            (state / 'state.json').write_text(json.dumps({
                'gateway_id': GATEWAY, 'network_id': 'net-other',
                'applied_generation': 2, 'applied_config_id': 'cfg-2',
            }))
            invalid = subprocess.run(
                ['bash', str(ROOT / 'remote-gateway-observation.sh'), RUN, GATEWAY, NETWORK, CLIENT],
                env={**self.env(root), 'XCONNECT_GATEWAY_STATE_DIR': str(state)},
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(invalid.returncode, 0, invalid.stderr)
            self.assertNotIn('refresh=OK', invalid.stdout)
            self.assertIn('signed_config=UNVERIFIED', invalid.stdout)

    def test_client_fragment_checks_bound_sync_and_gateway_peer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / 'one'
            state.mkdir()
            fixture_command(root, 'xconnect', f'''case "$1" in
  sync) exit 0 ;;
  status) printf '%s\\n' '{{"joined":true,"device_id":"{CLIENT}","network_id":"{NETWORK}","revision":"cfg-2","generations":{{"state":2}},"runtime":{{"applied":true,"core_id":"xray"}},"credential":{{"present":true,"expired":false}}}}' ;;
  *) exit 1 ;;
esac''')
            fixture_command(root, 'wg', f'echo "{KEY} $(date +%s)"')
            result = subprocess.run(
                ['bash', str(ROOT / 'remote-client-observation.sh'), CLIENT, NETWORK, KEY],
                env={**self.env(root), 'XCONNECT_ONE_STATE_DIR': str(state)},
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('sync=OK', result.stdout)
            self.assertIn('client_peer=OBSERVED', result.stdout)
            fixture_command(root, 'xconnect', f'''case "$1" in
  sync) exit 0 ;;
  status) printf '%s\\n' '{{"joined":true,"device_id":"{CLIENT}","network_id":"{NETWORK}","revision":"cfg-2","generations":{{"state":2}},"runtime":{{"applied":true,"core_id":"wrong"}},"credential":{{"present":true,"expired":false}}}}' ;;
  *) exit 1 ;;
esac''')
            invalid = subprocess.run(
                ['bash', str(ROOT / 'remote-client-observation.sh'), CLIENT, NETWORK, KEY],
                env={**self.env(root), 'XCONNECT_ONE_STATE_DIR': str(state)},
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(invalid.returncode, 0, invalid.stderr)
            self.assertIn('signed_config=UNVERIFIED', invalid.stdout)


if __name__ == '__main__':
    unittest.main()
