#!/usr/bin/env python3
"""Freeze existing execution debt; new Toolkit code must remain control-plane-only."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

def command_pattern(commands):
    # Match an invocation, not a receipt key such as running_digests/docker or
    # a routing value such as provisioner=terraform. This is a review aid,
    # not a complete shell/Python security parser.
    return (r'(?m)(?:^\s*|[;&|]\s*|\$\()(?:(?:exec|sudo|command|run_gcloud)\s+)?(?:' + commands + r')\s'
            + r'|[\[(]\s*[\"\x27](?:' + commands + r')[\"\x27]\s*,')


MARKERS = {
    'database_execution': command_pattern('pg_dump|pg_restore|psql'),
    'host_execution': command_pattern('ssh|ansible-playbook|ansible|docker'),
    'provider_execution': command_pattern('terraform|gcloud|wrangler') + r'|\bcurl\b[^\n]*(?:-X|--request)\s+(?:POST|PUT|PATCH|DELETE)\b',
}


def inventory(root):
    paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '.github/scripts'], text=True).splitlines()
    found = {}
    for relative in paths:
        path = root / relative
        if not path.is_file() or path.suffix not in {'.sh', '.py', '.rb'}:
            continue
        if 'tests' in path.parts or path.name.startswith('test_') or path.name.endswith('_test.sh'):
            continue
        source = '\n'.join(line for line in path.read_text().splitlines() if not line.lstrip().startswith('#'))
        matched = [name for name, pattern in MARKERS.items() if re.search(pattern, source)]
        if not matched:
            continue
        found[relative] = {'owner': 'playbooks' if '/serverless/' in relative or any(x in matched for x in ('database_execution', 'host_execution')) else 'iac_modules',
                           'markers': matched, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    return found


def verify(root, registry):
    current = inventory(root)
    entries = registry.get('legacy_execution', {})
    errors = []
    for path, entry in current.items():
        if path not in entries:
            errors.append('new execution logic must move to its owner: ' + path)
        elif entry != entries[path]:
            errors.append('legacy execution changed; migrate instead of extending: ' + path)
    if errors:
        raise SystemExit('\n'.join('::error::' + error for error in errors))
    print(f'Control-plane boundary verified; {len(current)} frozen legacy execution candidates remain (not fully migrated).')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--inventory-only', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    if args.inventory_only:
        print(json.dumps({'schema': 1, 'policy': 'frozen-legacy-debt-not-an-exemption-for-new-code', 'legacy_execution': inventory(root)}, indent=2, sort_keys=True))
    else:
        verify(root, json.loads((root / 'scripts/ci/legacy-execution-inventory.json').read_text()))


if __name__ == '__main__':
    main()
