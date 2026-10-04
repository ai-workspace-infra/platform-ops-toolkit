#!/usr/bin/env python3
"""Publish allowlisted Actions evidence, never logs or arbitrary artifact fields."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import base64
from datetime import datetime, timedelta, timezone
import io
from functools import lru_cache
import json
from pathlib import Path
import re
import subprocess
import zipfile

REPO = 'ai-workspace-infra/platform-ops-toolkit'
BRANCH = 'release-status'
TAG = re.compile(r'^(?:(?:uat-)?daily-build-\d{4}\.\d{2}\.\d{2}(?:-r[1-9]\d*)?|v[0-9][A-Za-z0-9._-]*)$')
WORKFLOWS = ('daily-main-snapshot.yaml', 'serverless-orchestrator.yml')

def api(path, payload=None, binary=False):
    cmd = ['gh', 'api', path, '--allow-escape-sequences']
    if payload is not None:
        cmd += ['--method', 'PUT' if '/contents/' in path else 'POST', '--input', '-']
    data = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120, input=json.dumps(payload).encode() if payload is not None else None).stdout
    return data if binary else json.loads(data)

@lru_cache(maxsize=1000)
def artifact_listing(run_id):
    return api(f'repos/{REPO}/actions/runs/{run_id}/artifacts?per_page=100')

def artifact(run_id, name, filename, not_before=""):
    listing = artifact_listing(run_id)
    matches = [a for a in listing['artifacts'] if a['name'] == name and not a['expired'] and a['created_at'] >= not_before]
    if not matches:
        return None
    item = max(matches, key=lambda a: a['id'])
    if item['size_in_bytes'] > 2_000_000:
        raise ValueError('Oversized status artifact')
    raw = api(f'repos/{REPO}/actions/artifacts/{item["id"]}/zip', binary=True)
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        info = archive.getinfo(filename)
        if info.file_size > 4_000_000:
            raise ValueError('Oversized status document')
        return json.loads(archive.read(info))

def jobs(run):
    result = []
    page = 1
    while True:
        rows = api(f'repos/{REPO}/actions/runs/{run["id"]}/attempts/{run["run_attempt"]}/jobs?per_page=100&page={page}')['jobs']
        result.extend(rows)
        if len(rows) < 100:
            return result
        page += 1

def build_state(raw):
    if raw == 'build_succeeded': return 'success'
    if raw in ('build_failed', 'manifest_missing', 'conflict', 'tag_failed'): return 'failed'
    if raw == 'skipped': return 'skipped'
    if raw in ('dispatched', 'build_timeout', 'build_lookup_failed'): return 'pending'
    return 'unknown'

def snapshot_records(run, rows, run_jobs):
    # Each repository emits several lifecycle events. Last event is authoritative.
    grouped = {}
    for row in rows:
        env, tag, repo = row.get('environment'), row.get('tag', ''), row.get('repository', '')
        if env not in ('uat', 'prod') or not TAG.fullmatch(tag): continue
        if not re.fullmatch(r'ai-workspace-(?:infra|lab|services|xstream)/[A-Za-z0-9._-]+', repo): continue
        grouped.setdefault((env, tag), {})[repo] = {
            'repository': repo, 'tag': tag, 'sha': row.get('sha', '') if re.fullmatch(r'[a-f0-9]{40}', row.get('sha', '')) else '',
            'build': build_state(row.get('status')), 'deployment': 'unknown',
        }
    summary = next((j for j in run_jobs if j['name'] == 'Summarize daily snapshot status'), {})
    dispatch = next((s for s in summary.get('steps', []) if s['name'] == 'Dispatch UAT Hybrid Orchestrator'), {})
    canonical = {(e, t) for e, t in grouped if any(r.startswith('ai-workspace-services/') for r in grouped[(e, t)])}
    records = []
    for (env, tag), repos in grouped.items():
        accepted = env == 'uat' and len(canonical) == 1 and (env, tag) in canonical and run['conclusion'] == 'success' and dispatch.get('conclusion') == 'success'
        verdict = 'success' if accepted else ('failed' if run['conclusion'] in ('failure', 'timed_out', 'cancelled') else 'pending' if run['status'] != 'completed' else 'unknown')
        # Snapshot repos also include build-only tooling. Do not paint those as deployed.
        deployed = {'accounts', 'billing-service', 'content-service', 'portal', 'frontend-router', 'edge-gateway'}
        for repo, value in repos.items():
            if repo.startswith('ai-workspace-services/') and repo.split('/')[1] in deployed:
                value['deployment'] = 'success' if accepted else 'unknown'
        records.append(record(run, env, tag, 'full-uat', verdict, list(repos.values()), (dispatch.get('completed_at') or summary.get('completed_at')) if accepted else run['updated_at']))
    return records

def record(run, env, tag, scope, verdict, repos, completed):
    return {'id': f'{run["id"]}:{run["run_attempt"]}:{env}:{tag}', 'runId': run['id'], 'attempt': run['run_attempt'],
            'environment': env, 'tag': tag, 'scope': scope, 'status': verdict,
            'workflow': run['path'].split('/')[-1], 'url': f'https://github.com/{REPO}/actions/runs/{run["id"]}',
            'startedAt': run['created_at'], 'completedAt': completed, 'repositories': repos}

def serverless_records(run, metadata, run_jobs):
    env, tag = metadata.get('environment'), metadata.get('tag', '')
    if env not in ('uat', 'prod') or not TAG.fullmatch(tag): return []
    if metadata.get('operation') not in ('deploy', 'upgrade', 'deploy+migrate'): return []
    lanes = metadata.get('lanes', {})
    required = ('preflight', 'cloud_run', 'cloudflare_ssr', 'frontend_router', 'edge_gateway', 'static_pages', 'serverless_domains', 'verify')
    full = all(lanes.get(k, {}).get('result') == 'success' for k in required)
    required_jobs = [f'Cloud Run / {service}' for service in ('accounts', 'billing-service', 'content-service')]
    required_jobs += [f'Cloudflare / SSR / {boundary}' for boundary in ('public', 'content', 'auth', 'console', 'workspace')]
    required_jobs += [f'Cloudflare / Edge Gateway {boundary}' for boundary in ('Auth', 'Admin', 'Router Core')]
    complete_matrix = all(any(j['name'] == name and j['conclusion'] == 'success' for j in run_jobs) for name in required_jobs)
    accepted = full and complete_matrix and run['conclusion'] == 'success' and metadata.get('target') in ('all', 'web-saas')
    verdict = 'success' if accepted else 'failed' if run['conclusion'] in ('failure', 'timed_out', 'cancelled') else 'unknown'
    repos = []
    for service in ('accounts', 'billing-service', 'content-service', 'portal', 'frontend-router', 'edge-gateway'):
        names = {'portal': ('Cloudflare / SSR /', 'Cloudflare / static-pages'), 'frontend-router': ('Cloudflare / frontend-router',), 'edge-gateway': ('Cloudflare / Edge Gateway ',)}.get(service, (f'Cloud Run / {service}',))
        matching = [j for j in run_jobs if any(j['name'].startswith(n) for n in names)]
        state = 'success' if matching and all(j['conclusion'] == 'success' for j in matching) else 'failed' if any(j['conclusion'] == 'failure' for j in matching) else 'unknown'
        repos.append({'repository': f'ai-workspace-services/{service}', 'tag': tag, 'sha': '', 'build': 'unknown', 'deployment': state})
    verified = next((j.get('completed_at') for j in run_jobs if j['name'] == 'Verify / Summary' and j.get('completed_at')), None)
    return [record(run, env, tag, 'serverless', verdict, repos, verified or run['updated_at'])]

def legacy_serverless_metadata(run, run_jobs):
    """Recover only four public dispatch fields from retained preflight logs."""
    preflight = next((j for j in run_jobs if j['name'] == 'Validate / Dispatch inputs'), None)
    if not preflight: return None
    raw = api(f'repos/{REPO}/actions/jobs/{preflight["id"]}/logs', binary=True)
    if len(raw) > 5_000_000: return None
    text = raw.decode('utf-8', errors='replace')
    values = {}
    for field, pattern in {'environment': ('VAULT_ENV_PATH', r'uat|prod|sit'),
                           'tag': ('TAG_REF', r'[A-Za-z0-9._-]+'),
                           'operation': ('OPERATION', r'[a-z+-]+'),
                           'target': ('TARGET_DOMAINS', r'[a-z -]+')}.items():
        key, allowed = pattern
        found = set(re.findall(r'^\S+\s+  ' + key + r': (' + allowed + r')\s*$', text, re.M))
        if len(found) != 1: return None
        values[field] = found.pop()
    patterns = {'preflight': ('Validate / Dispatch inputs',), 'cloud_run': ('Cloud Run / ',),
                'cloudflare_ssr': ('Cloudflare / SSR / ',), 'frontend_router': ('Cloudflare / frontend-router',),
                'edge_gateway': ('Cloudflare / Edge Gateway ',),
                'static_pages': ('Cloudflare / static-pages',), 'serverless_domains': ('Cloudflare / custom domains',),
                'verify': ('Verify / Summary',)}
    values['lanes'] = {}
    for lane, names in patterns.items():
        matching = [j for j in run_jobs if any(j['name'].startswith(n) for n in names)]
        values['lanes'][lane] = {'result': 'success' if matching and all(j['conclusion'] == 'success' for j in matching) else 'unknown'}
    return values

def trusted_run(run):
    return (run.get('head_branch') == 'main' and
            (run.get('head_repository') or {}).get('full_name') == REPO and
            run.get('event') in ('schedule', 'workflow_dispatch'))

def collect(existing, days):
    now = datetime.now(timezone.utc)
    cutoff = (now - timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%SZ')
    records = {r['id']: r for r in existing.get('releases', [])}
    gaps = []
    observations = dict(existing.get('observedRuns', {}))
    old_gaps = {g['runId']: g for g in existing.get('gaps', [])}
    for workflow in WORKFLOWS:
        page = 1
        while True:
            listing = api(f'repos/{REPO}/actions/workflows/{workflow}/runs?per_page=100&page={page}&created=%3E%3D{cutoff}')
            def hydrate(run):
                if not trusted_run(run): return [], None
                signature = f'{run["run_attempt"]}:{run["updated_at"]}'
                if run['status'] == 'completed' and observations.get(str(run['id'])) == signature:
                    return [], old_gaps.get(run['id'])
                try:
                    run_jobs = jobs(run)
                    started = min((j['started_at'] for j in run_jobs if j.get('started_at')), default=run['created_at'])
                    if workflow == WORKFLOWS[0]:
                        rows = artifact(run['id'], 'daily-snapshot-summary-uat', 'daily-snapshot-summary.json', started)
                        if rows is None: rows = artifact(run['id'], 'daily-snapshot-summary-prod', 'daily-snapshot-summary.json', started)
                        new = snapshot_records(run, rows, run_jobs) if rows is not None else []
                    else:
                        meta = artifact(run['id'], 'console-release-metadata', 'release-metadata.json', started)
                        if meta is None: meta = legacy_serverless_metadata(run, run_jobs)
                        new = serverless_records(run, meta, run_jobs) if meta is not None else []
                    if run['status'] == 'completed': observations[str(run['id'])] = signature
                    return new, None if new else {'runId': run['id'], 'workflow': workflow, 'status': run['status'], 'reason': 'No immutable release evidence'}
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError, zipfile.BadZipFile):
                    return [], {'runId': run['id'], 'workflow': workflow, 'status': run['status'], 'reason': 'Status artifact unavailable'}
            with ThreadPoolExecutor(max_workers=6) as pool:
                for new, gap in pool.map(hydrate, listing['workflow_runs']):
                    for r in new: records[r['id']] = r
                    if gap: gaps.append(gap)
            if len(listing['workflow_runs']) < 100: break
            page += 1
    return {'schemaVersion': 1, 'source': 'github-actions', 'updatedAt': now.isoformat(), 'timezone': 'Asia/Shanghai',
            'coverage': {'since': min(existing.get('coverage', {}).get('since', cutoff), cutoff), 'refreshDays': days,
                         'prod': 'Serverless metadata and retained dispatch evidence; selfhost deployments and runs without immutable identity are not covered'},
            'observedRuns': observations, 'gaps': gaps, 'releases': sorted(records.values(), key=lambda r: r['startedAt'], reverse=True)}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--days', type=int, default=30)
    parser.add_argument('--output', required=True)
    parser.add_argument('--publish', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.days <= 90: parser.error('days must be 1..90')
    path = f'repos/{REPO}/contents/releases.json?ref={BRANCH}'
    try:
        old = api(path)
        encoded = old.get('content') or api(f'repos/{REPO}/git/blobs/{old["sha"]}')['content']
        existing = json.loads(base64.b64decode(encoded))
    except subprocess.CalledProcessError:
        old, existing = {}, {}
    payload = collect(existing, args.days)
    Path(args.output).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n')
    if args.publish:
        try: api(f'repos/{REPO}/git/ref/heads/{BRANCH}')
        except subprocess.CalledProcessError:
            head = api(f'repos/{REPO}/git/ref/heads/main')['object']['sha']
            api(f'repos/{REPO}/git/refs', {'ref': f'refs/heads/{BRANCH}', 'sha': head})
        body = {'message': 'chore: refresh release status evidence', 'branch': BRANCH,
                'content': base64.b64encode(Path(args.output).read_bytes()).decode()}
        if old: body['sha'] = old['sha']
        api(f'repos/{REPO}/contents/releases.json', body)
    print(f'{len(payload["releases"])} release attempts; {len(payload["gaps"])} evidence gaps')

if __name__ == '__main__': main()
