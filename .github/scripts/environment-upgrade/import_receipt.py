"""Fail-closed acceptance of an exact legacy-import child (control plane only)."""
import json
import re


def validate(receipt, inputs, run, owner_sha):
    config = json.loads(inputs['config_json'])
    expected = {
        'schema': 'uat-data-import/v1', 'environment': inputs['environment'],
        'correlation_id': inputs['correlation_id'], 'run_id': str(run['id']),
        'run_attempt': str(run.get('run_attempt', 1)), 'owner_sha': owner_sha,
        'accounts_ref': inputs['accounts_ref'], 'dry_run': config.get('dry_run', True),
        'target_host': config.get('accounts_target_host', ''),
        'caller_run_id': str(config.get('caller_run_id', '')),
    }
    if not isinstance(receipt, dict) or any(type(receipt.get(k)) is not type(v) or receipt[k] != v for k, v in expected.items()):
        raise ValueError('Import receipt does not match the exact requested child, source or target')
    sha = receipt.get('accounts_sha', '')
    if not isinstance(sha, str) or not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Import receipt is missing the actual Accounts commit')
    if re.fullmatch(r'[0-9a-f]{40}', inputs['accounts_ref']) and sha != inputs['accounts_ref']:
        raise ValueError('Import receipt Accounts commit mismatch')
    if receipt.get('success') is not True:
        raise ValueError('Import owner did not report success')
    if (config.get('accounts_transport', 'ssh') == 'direct'
            and config.get('accounts_target_backend', 'vps') == 'vps'
            and config.get('accounts_migration_mode', 'data') == 'data'):
        runtime = receipt.get('runtime', {})
        if not isinstance(runtime, dict) or runtime.get('category') != 'success':
            raise ValueError('Direct import lacks a successful runtime receipt')
        if expected['dry_run']:
            accepted = (runtime.get('phase') == 'target_preview'
                        and runtime.get('write_state') == 'not_attempted'
                        and runtime.get('convergence_verified') is False)
        else:
            accepted = (runtime.get('phase') == 'target_verify'
                        and runtime.get('write_state') == 'verified'
                        and runtime.get('convergence_verified') is True)
        if not accepted:
            raise ValueError('Import preview or applied convergence is not verified')
    # Preserve only audited fields, never arbitrary artifact payloads.
    accepted = {key: receipt[key] for key in (*expected, 'accounts_sha', 'success')}
    runtime = receipt.get('runtime')
    if isinstance(runtime, dict) and runtime.get('category') == 'success':
        accepted['runtime'] = {key: runtime[key] for key in ('phase', 'category', 'write_state', 'convergence_verified') if key in runtime}
    return accepted
