import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('collector', Path(__file__).with_name('collect.py'))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
RUN = {'id':1,'run_attempt':1,'conclusion':'success','status':'completed','created_at':'2026-10-03T00:00:00Z','updated_at':'2026-10-03T01:00:00Z','path':'.github/workflows/daily-main-snapshot.yaml'}
ROWS = [{'environment':'uat','tag':'daily-build-2026.10.03','repository':'ai-workspace-services/accounts','status':'unchanged','sha':'a'*40}, {'environment':'uat','tag':'daily-build-2026.10.03','repository':'ai-workspace-services/accounts','status':'build_succeeded','sha':'a'*40}]
class EvidenceTests(unittest.TestCase):
    def test_artifact_from_previous_attempt_is_excluded(self):
        listing = {'artifacts': [{'id': 7, 'name': 'summary', 'expired': False,
                                 'created_at': '2026-10-03T00:00:00Z', 'size_in_bytes': 100}]}
        with patch.object(c, 'artifact_listing', return_value=listing), patch.object(c, 'api') as download:
            self.assertIsNone(c.artifact(1, 'summary', 'summary.json', '2026-10-03T02:00:00Z'))
            download.assert_not_called()
    def test_untrusted_sources_are_excluded(self):
        run = {**RUN, 'head_branch':'main','head_repository':{'full_name':c.REPO},'event':'workflow_dispatch'}
        self.assertTrue(c.trusted_run(run))
        self.assertFalse(c.trusted_run({**run,'head_repository':{'full_name':'attacker/fork'}}))
        self.assertFalse(c.trusted_run({**run,'event':'pull_request'}))
        self.assertFalse(c.trusted_run({**run,'head_branch':'feature'}))
    def test_build_only_is_not_a_release(self):
        record = c.snapshot_records(RUN, ROWS, [])[0]
        self.assertEqual(record['status'],'unknown')
        self.assertEqual(len(record['repositories']),1)
        self.assertEqual(record['repositories'][0]['build'],'success')
        self.assertEqual(record['repositories'][0]['deployment'],'unknown')
    def test_actual_dispatch_accepts_release(self):
        job = {'name':'Summarize daily snapshot status','completed_at':RUN['updated_at'],'steps':[{'name':'Dispatch UAT Hybrid Orchestrator','conclusion':'success'}]}
        self.assertEqual(c.snapshot_records(RUN,ROWS,[job])[0]['status'],'success')
        job['steps'][0]['conclusion']='skipped'
        self.assertEqual(c.snapshot_records(RUN,ROWS,[job])[0]['status'],'unknown')
    def test_missing_and_partial_prod_gates_cannot_accept(self):
        meta={'environment':'prod','tag':'v1.0.0','operation':'plan','target':'all','lanes':{}}
        self.assertEqual(c.serverless_records(RUN,meta,[]),[])
        meta['operation']='deploy'
        self.assertEqual(c.serverless_records(RUN,meta,[])[0]['status'],'unknown')
    def test_partial_service_matrix_is_not_a_full_prod_release(self):
        keys = ('preflight','cloud_run','cloudflare_ssr','frontend_router','edge_gateway','static_pages','serverless_domains','verify')
        meta = {'environment':'prod','tag':'v1.0.0','operation':'upgrade','target':'web-saas','lanes':{k:{'result':'success'} for k in keys}}
        jobs = [{'name':f'Cloud Run / {service}','conclusion':'success'} for service in ('accounts','billing-service','content-service')]
        jobs += [{'name':f'Cloudflare / SSR / {b}','conclusion':'success'} for b in ('public','content','auth','console','workspace')]
        jobs += [{'name':f'Cloudflare / Edge Gateway {b}','conclusion':'success'} for b in ('Auth','Admin','Router Core')]
        self.assertEqual(c.serverless_records(RUN,meta,jobs)[0]['status'],'success')
        self.assertEqual(c.serverless_records(RUN,meta,jobs[1:])[0]['status'],'unknown')
    def test_mutable_ref_is_excluded(self):
        self.assertEqual(c.snapshot_records(RUN,[{**ROWS[0],'tag':'main'}],[]),[])
if __name__ == '__main__': unittest.main()
