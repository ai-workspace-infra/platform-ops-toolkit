#!/usr/bin/env python3
"""Review/provenance for isolated runtime images; no host or DB execution."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile

loader=importlib.util.spec_from_file_location('native_init_control',Path(__file__).with_name('native_init_control.py'))
INIT=importlib.util.module_from_spec(loader);loader.loader.exec_module(INIT)
BASE=INIT.BASE
require=BASE.require


def validate_inputs(event,ref,sha,repository,attempt):
    operation=(event.get('inputs') or {}).get('operation')
    require(operation in ('native-runtime-plan','native-runtime-qualify') and attempt=='1',
            'Explicit first-attempt managed runtime image operation required')
    normalized={**event,'inputs':{**event['inputs'],'operation':'native-standby'}}
    BASE.validate_inputs(normalized,ref,sha,repository)
    return operation=='native-runtime-plan'


def validate_review(environment,run,reviews,run_id,sha,ref):
    require(run.get('id')==int(run_id) and run.get('run_attempt')==1 and
            run.get('event')=='workflow_dispatch' and run.get('head_sha')==sha and
            run.get('head_branch')==ref.removeprefix('refs/tags/') and
            run.get('repository',{}).get('full_name')==BASE.REPOSITORY,
            'Current managed image qualification run differs')
    require(environment.get('name')=='prod' and type(environment.get('id')) is int,
            'Production qualification environment differs')
    rules=[r for r in environment.get('protection_rules',[]) if r.get('type')=='required_reviewers']
    require(len(rules)==1 and rules[0].get('reviewers'), 'Production image review is not configured')
    allowed={r.get('reviewer',{}).get('login') for r in rules[0]['reviewers'] if r.get('type')=='User'}
    allowed.discard(None)
    actors={a.get('login') for a in (run.get('actor') or {},run.get('triggering_actor') or {})}
    actors.discard(None)
    # Images run with network=none, no DB/service credential and no business
    # handler. Honor the actual environment policy; never use this review or
    # receipt as the independent data approval for init/copy/cutover.
    require(any(r.get('state')=='approved' and r.get('user',{}).get('login') in allowed and
                (rules[0].get('prevent_self_review') is not True or r['user']['login'] not in actors) and
                any(e.get('id')==environment['id'] and e.get('name')=='prod' for e in r.get('environments',[]))
                for r in reviews), 'This run has no configured production image reviewer approval')


def validate_spec(spec):
    require(isinstance(spec,dict) and set(spec)=={'schema','environment','host','services'} and
            type(spec['schema']) is int and spec['schema']==1 and spec['environment']=='prod' and
            spec['host']=='web-saas-prod', 'Managed image target differs')
    require(isinstance(spec['services'],dict) and set(spec['services'])=={'accounts','billing'},
            'Both service image contracts are required')
    for name,repo in [('accounts','accounts'),('billing','billing-service')]:
        service=spec['services'][name]
        require(isinstance(service,dict) and set(service)=={'commit','image','image_digest'} and
                isinstance(service['commit'],str) and re.fullmatch('[0-9a-f]{40}',service['commit']) and
                service['image']=='ghcr.io/ai-workspace-services/'+repo+':sha-'+service['commit'] and
                isinstance(service['image_digest'],str) and re.fullmatch('sha256:[0-9a-f]{64}',service['image_digest']),
                'Managed image source/digest contract differs')


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--contract',type=Path,required=True)
    parser.add_argument('--destination',type=Path,required=True)
    parser.add_argument('--spec-output',type=Path,required=True)
    args=parser.parse_args()
    require(os.environ.get('GITHUB_EVENT_NAME')=='workflow_dispatch','Explicit image dispatch required')
    dry_run=validate_inputs(json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()),
                            os.environ['GITHUB_REF'],os.environ['GITHUB_SHA'],os.environ['GITHUB_REPOSITORY'],
                            os.environ['GITHUB_RUN_ATTEMPT'])
    run_id=os.environ['GITHUB_RUN_ID'];get=BASE.get_json
    validate_review(get('/environments/prod'),get('/actions/runs/'+run_id),get('/actions/runs/'+run_id+'/approvals'),
                    run_id,os.environ['GITHUB_SHA'],os.environ['GITHUB_REF'])
    contract=json.loads(args.contract.read_text())
    require(contract.get('schema')==1 and contract.get('scope')=='prod-managed-runtime-qualification-only',
            'Image qualification scope differs')
    validate_spec(contract['runtime'])
    for key in ('gitops_commit','iac_commit','playbooks_commit'):
        require(re.fullmatch('[0-9a-f]{40}',contract.get(key,'')), 'Fixed execution owner SHA required')
    source=contract['resource'];standby=contract['standby']
    run=get('/actions/runs/'+str(source['run_id']))
    BASE.validate_provenance(contract,run,get('/actions/workflows/'+str(run['workflow_id'])),
                             get('/actions/artifacts/'+str(source['artifact_id'])))
    run=get('/actions/runs/'+str(standby['run_id']))
    INIT.validate_standby(contract,run,get('/actions/workflows/'+str(run['workflow_id'])),
                          get('/actions/artifacts/'+str(standby['artifact_id'])))
    with tempfile.TemporaryDirectory(dir=os.environ['RUNNER_TEMP'],prefix='managed-runtime-evidence-') as d:
        work=Path(d)
        INIT.download(standby['artifact_id'],work/'standby.zip');INIT.validate_receipt(contract,work/'standby.zip')
        INIT.download(source['artifact_id'],work/'resource.zip');BASE.stage_archive(contract,work/'resource.zip',args.destination)
    require(not args.spec_output.exists(),'Runtime specification output must be fresh')
    with args.spec_output.open('x') as output:
        output.write(json.dumps(contract['runtime'],sort_keys=True)+'\n')
    args.spec_output.chmod(0o600)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'],'a') as out:
            out.write('dry_run='+str(dry_run).lower()+'\n')
            out.write('gitops_commit='+contract['gitops_commit']+'\n')
            out.write('cmdb_sha256='+source['cmdb_sha256']+'\n')
            out.write('runtime_gate_verified=true\n')
    print('Configured production image review and original resource/standby evidence verified; no data approval or host action.')


if __name__=='__main__':
    try:main()
    except Exception:
        print('Managed image control stopped before registry credentials or host access.')
        raise SystemExit(1)
