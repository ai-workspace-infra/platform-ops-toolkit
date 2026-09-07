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


if __name__ == '__main__':
    unittest.main()
