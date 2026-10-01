#!/usr/bin/env python3
"""Exercise real Hybrid dispatch/wait without contacting GitHub or cloud APIs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
DISPATCHER = ROOT / '.github/scripts/platform-ops/provision/platform-ops_dispatch-hybrid-uat-matrix.sh'


class HybridChildWaitTest(unittest.TestCase):
    def run_case(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            rows = [dict(order=1, namespace='open-platform', release_scope='shared-infrastructure')]
            rows += [dict(order=i, namespace=f'lane-{i}', release_scope='business',
                          management_mode='terraform', lifecycle='ephemeral', provider='aws-cloud',
                          account='081434641398', profile='2C2G') for i in range(2, 9)]
            matrix = work / 'matrix.json'
            matrix.write_text(json.dumps({'spec': {'resources': rows, 'xconnect_network': {
                'id': 'net_uat', 'gateway_ref': 'gateway.example.test'}}}))
            fake = work / 'gh'
            fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['FAKE_STATE'])
s = json.loads(p.read_text()) if p.exists() else {'dispatch': 0, 'reads': 0}
a = sys.argv[1:]
if a[:2] == ['run', 'list']:
    rows = [{'databaseId': s['dispatch'], 'headBranch': 'main', 'createdAt': '2099-01-01T00:00:00Z'}]
    if os.environ['FAKE_MODE'] == 'ambiguous':
        rows.append(dict(rows[0], databaseId=999))
    print(json.dumps(rows))
elif a[0] == 'api' and '--method' in a:
    s['dispatch'] += 1
    s['reads'] = 0
    sys.stdin.read()
elif a[0] == 'api' and '/actions/runs/' in a[1]:
    s['reads'] += 1
    p.write_text(json.dumps(s))
    if os.environ['FAKE_MODE'] == 'recover' and s['reads'] == 1:
        sys.exit(1)
    if os.environ['FAKE_MODE'] == 'recover' and s['reads'] == 2:
        print('in_progress\\t')
    else:
        print('completed\\t' + ('failure' if os.environ['FAKE_MODE'] == 'failure' else 'success'))
else:
    sys.exit('Unexpected gh call: ' + repr(a))
p.write_text(json.dumps(s))
''')
            fake.chmod(0o755)
            sleep = work / 'sleep'
            sleep.write_text('#!/bin/sh\nexit 0\n')
            sleep.chmod(0o755)
            env = dict(os.environ, PATH=f'{work}:{os.environ["PATH"]}', FAKE_MODE=mode,
                       FAKE_STATE=str(work / 'state.json'), GH_TOKEN='fake-test-only',
                       GH_REPO='owner/repo', MATRIX_FILE=str(matrix), OPERATION='plan',
                       CHILD_REF='main', VAULT_ENV_PATH='uat', TARGET_DOMAIN_BASE='onwalk.net',
                       OBSERVABILITY_ENDPOINT='https://monitor.example.test')
            result = subprocess.run(['bash', str(DISPATCHER)], env=env, cwd=ROOT,
                                    capture_output=True, text=True, timeout=30)
            state = json.loads((work / 'state.json').read_text())
            return result, state

    def test_transient_reads_do_not_redispatch_or_fail_live_children(self):
        result, state = self.run_case('recover')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state['dispatch'], 7)
        self.assertEqual(state['reads'], 3)

    def test_terminal_child_failure_stops_later_lanes(self):
        result, state = self.run_case('failure')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('completed with failure', result.stderr)
        self.assertEqual(state['dispatch'], 1)

    def test_ambiguous_runs_cannot_supply_acceptance_evidence(self):
        result, state = self.run_case('ambiguous')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Multiple selfhost-orchestrator.yml runs match', result.stderr)
        self.assertEqual(state['dispatch'], 1)
        self.assertEqual(state['reads'], 0)


if __name__ == '__main__':
    unittest.main()
