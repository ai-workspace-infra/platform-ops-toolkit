import importlib.util
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('domain_selector', ROOT / '.github/scripts/serverless/select-domain-owner.py')
selector = importlib.util.module_from_spec(spec); spec.loader.exec_module(selector)
SHA = 'a'*40


class DomainOwnerTests(unittest.TestCase):
    def test_production_gtm_has_one_gateway_publisher(self):
        cfg = {'kind': 'EdgeRoutingConfig', 'metadata': {'environment': 'prod'},
               'spec': {'runtime': {'routing': {'dns': {'api_alias_mode': 'worker-routes-cname'}}}}}
        self.assertEqual(selector.select(cfg, 'prod', SHA), {'gitops_ref': SHA, 'guarded_api_gateway': 'true'})
        cfg['spec']['runtime']['routing']['dns'] = {}
        self.assertEqual(selector.select(cfg, 'prod', SHA)['guarded_api_gateway'], 'true')
        with self.assertRaises(ValueError): selector.select(cfg, 'uat', SHA)
        with self.assertRaises(ValueError): selector.select(cfg, 'prod', 'main')
        cfg['metadata']['environment'] = 'uat'
        self.assertEqual(selector.select(cfg, 'uat', SHA)['guarded_api_gateway'], 'false')

    def test_workflow_uses_pinned_provider_and_keeps_http_verification(self):
        path = ROOT / '.github/workflows/serverless-orchestrator.yml'
        text = path.read_text(); jobs = yaml.safe_load(text)['jobs']
        owner = jobs['serverless_domains_provider']
        self.assertRegex(owner['uses'], r'^ai-workspace-infra/iac_modules/\.github/workflows/cloudflare-serverless-domains.yml@[a-f0-9]{40}$')
        self.assertEqual(owner['with']['gitops_ref'], '${{ needs.preflight.outputs.gitops_ref }}')
        self.assertNotIn('steps', owner)
        self.assertIn("needs.preflight.outputs.guarded_api_gateway != 'true'", jobs['edge_gateway']['if'])
        self.assertIn('serverless_domains_provider', jobs['serverless_domains']['needs'])
        verification = jobs['serverless_domains']['steps']
        self.assertTrue(any('verify_brand_site_review_readiness.sh' in step.get('run', '') for step in verification))
        self.assertTrue(any('verify_serverless_public_chain.sh' in step.get('run', '') for step in verification))
        self.assertNotIn('run: ./scripts/serverless_uat/reconcile_cloudflare_domains.sh', text)


if __name__ == '__main__': unittest.main()
