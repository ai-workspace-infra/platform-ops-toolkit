"""Offline tests of safe labels and the actual shell wrapper; no Terraform/cloud."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('diagnostics', SCRIPTS / 'terraform-diagnostics.py')
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class SafeDiagnostics(unittest.TestCase):
    def fixture(self):
        return {'type': 'diagnostic', 'diagnostic': {
            'severity': 'error', 'address': 'aws_instance.gateway',
            'summary': 'modifying EC2 Instance (i-secret) InstanceInitiatedShutdownBehavior attribute',
            'detail': 'operation error EC2: ModifyInstanceAttribute, api error Unsupported: '
                      'AWS_SESSION_TOKEN=secret-session, vault=xrt_private, '
                      'https://secret.invalid/key?token=hidden\n::warning::injection'}}

    def test_classification_never_emits_provider_text(self):
        result = diagnostics.summarize('apply', json.dumps(self.fixture()), 1)
        for expected in ('aws_instance.gateway', 'api=ModifyInstanceAttribute',
                         'code=Unsupported', 'attribute=InstanceInitiatedShutdownBehavior'):
            self.assertIn(expected, result)
        for forbidden in ('i-secret', 'secret-session', 'xrt_private', 'https:',
                          'hidden', '::warning::', '\n'):
            self.assertNotIn(forbidden, result)

    def test_validate_json_and_multiple_errors(self):
        first = self.fixture()['diagnostic']
        second = {'severity': 'error', 'address': 'aws_instance.client',
                  'detail': 'RunInstances: InsufficientInstanceCapacity'}
        result = diagnostics.summarize('validate', json.dumps({'diagnostics': [first, second]}), 1)
        self.assertIn('resource=aws_instance.gateway,aws_instance.client', result)
        self.assertIn('api=RunInstances,ModifyInstanceAttribute', result)
        self.assertIn('InsufficientInstanceCapacity', result)

    def test_normal_progress_and_warnings_are_not_errors(self):
        warning = self.fixture()
        warning['diagnostic']['severity'] = 'warning'
        raw = '\n'.join((json.dumps(warning), json.dumps({'type': 'planned_change',
                          'detail': 'RunInstances UnauthorizedOperation aws_instance.client'})))
        result = diagnostics.summarize('plan', raw, 1)
        self.assertIn('api=unclassified', result)
        self.assertIn('code=unclassified', result)
        self.assertIn('resource=unclassified', result)

    def test_unknown_malformed_and_sensitive_data_fail_closed(self):
        for value in ('secret-token-123', '{"secret":broken}', 'null', '[]',
                      '{"diagnostics":"secret-value"}', '{"diagnostic":true}',
                      json.dumps({'type': 'diagnostic', 'diagnostic': {
                          'severity': 'error', 'detail': 'NewSecretError: private123'}})):
            result = diagnostics.summarize('apply', value, 1)
            self.assertIn('code=unclassified', result)
            self.assertNotIn('private123', result)
            self.assertNotIn('secret', result)

    def test_plain_startup_error_is_allowlisted_and_exact(self):
        result = diagnostics.summarize('init', 'AccessDeniedException secret-value', 1)
        self.assertIn('code=AccessDeniedException;', result)
        self.assertNotIn('code=AccessDenied,', result)
        self.assertNotIn('secret-value', result)

    def test_invalid_stage_cannot_inject_output(self):
        with self.assertRaises(ValueError):
            diagnostics.summarize('apply\n::warning::bad', '', 1)

    def test_shell_apply_returns_original_error_and_preserves_stage_log(self):
        with tempfile.TemporaryDirectory(prefix='xconnect-tf-diagnostics-') as temporary:
            root = Path(temporary)
            scripts = root / '.github/scripts/xconnect-lab'
            scripts.mkdir(parents=True)
            shutil.copyfile(SCRIPTS / 'terraform-diagnostics.py', scripts / 'terraform-diagnostics.py')
            (scripts / 'lease.sh').write_text('#!/usr/bin/env bash\nexit 0\n')
            lab = root / 'lab'
            lab.mkdir()
            (lab / 'backend-ready').touch()
            (lab / 'terraform-destroy.log').write_text('earlier-destroy-evidence')
            binary = root / 'bin'
            binary.mkdir()
            fake = binary / 'terraform'
            fake.write_text('#!/usr/bin/env bash\n'
                            'printf "%s\\n" "$@" > "$LAB_DIR/args"\n'
                            'printf "%s\\n" "$FAKE_DIAGNOSTIC"\nexit 7\n')
            fake.chmod(0o700)
            env = {'PATH': str(binary) + os.pathsep + os.environ['PATH'],
                   'GITHUB_WORKSPACE': str(root), 'LAB_DIR': str(lab),
                   'GITHUB_STEP_SUMMARY': str(root / 'summary'),
                   'FAKE_DIAGNOSTIC': json.dumps(self.fixture())}
            result = subprocess.run(['bash', str(SCRIPTS / 'run.sh'), 'apply'],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 7)
            self.assertIn('api=ModifyInstanceAttribute', result.stdout)
            self.assertNotIn('secret-session', result.stdout + result.stderr)
            self.assertNotIn('secret-session', (root / 'summary').read_text())
            self.assertEqual((lab / 'terraform-destroy.log').read_text(), 'earlier-destroy-evidence')
            self.assertIn('secret-session', (lab / 'terraform-apply.log').read_text())
            self.assertEqual((lab / 'terraform-apply.log').stat().st_mode & 0o777, 0o600)
            args = (lab / 'args').read_text().splitlines()
            self.assertEqual(args[1:], ['apply', '-no-color', '-json', '-input=false', str(lab / 'plan')])

    def test_private_output_and_state_read_failures_never_print_stderr(self):
        for stage, failing_command in [('apply', 'output'), ('cleanup', 'show')]:
            with self.subTest(stage=stage), tempfile.TemporaryDirectory(prefix='xconnect-tf-read-') as temporary:
                root = Path(temporary)
                scripts = root / '.github/scripts/xconnect-lab'
                scripts.mkdir(parents=True)
                shutil.copyfile(SCRIPTS / 'terraform-diagnostics.py', scripts / 'terraform-diagnostics.py')
                (scripts / 'lease.sh').write_text('#!/usr/bin/env bash\nexit 0\n')
                lab = root / 'lab'
                lab.mkdir()
                (lab / 'backend-ready').touch()
                (lab / 'apply-started').touch()
                (lab / 'run-id').write_text('xcl-123-1')
                binary = root / 'bin'
                binary.mkdir()
                fake = binary / 'terraform'
                fake.write_text('#!/usr/bin/env bash\n'
                                'printf "%s\\n" "$2" >> "$LAB_DIR/calls"\n'
                                'if [[ "$2" == "$FAIL_READ" ]]; then\n'
                                '  echo "AccessDenied secret-read-token" >&2\n'
                                '  exit 9\nfi\n')
                fake.chmod(0o700)
                env = {'PATH': str(binary) + os.pathsep + os.environ['PATH'],
                       'GITHUB_WORKSPACE': str(root), 'LAB_DIR': str(lab), 'MODE': 'apply',
                       'GITHUB_STEP_SUMMARY': str(root / 'summary'), 'FAIL_READ': failing_command}
                result = subprocess.run(['bash', str(SCRIPTS / 'run.sh'), stage],
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 9)
                self.assertIn('code=AccessDenied', result.stdout)
                self.assertIn('cleanup is unverified', result.stderr)
                self.assertNotIn('secret-read-token', result.stdout + result.stderr)
                self.assertNotIn('secret-read-token', (root / 'summary').read_text())
                self.assertIn('secret-read-token', (lab / f'terraform-{failing_command}.log').read_text())
                self.assertNotIn('destroy', (lab / 'calls').read_text())


if __name__ == '__main__':
    unittest.main()
