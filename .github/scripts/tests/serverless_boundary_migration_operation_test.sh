#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "${repo_root}" <<'PY'
from pathlib import Path
import importlib.util
import sys
import yaml
root = Path(sys.argv[1])
validator = root / 'scripts/serverless_uat/validate_cloudflare_boundaries.py'
source = root / '.github/workflows/serverless-orchestrator.yml'
text = source.read_text()
assert 'REQUESTED_OPERATION' not in validator.read_text(), 'GitOps topology must not authorize operations'
assert 'INITIALIZE_SUPABASE' not in text, 'Orchestrator must never initialize a live schema'
assert 'create_release_checkpoint.sh' not in text, 'Checkpoint execution belongs to Playbooks'
jobs = yaml.safe_load(text)['jobs']
assert 'exit 1' in jobs['init_schema']['steps'][0]['run'], 'Retired init must fail explicitly'
assert 'DATA_OPERATION: checkpoint' in text and 'environment-upgrade/dispatch.py' in text
spec = importlib.util.spec_from_file_location('boundaries', validator)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.validate_data_topology({'primary':'serverless', 'replica':'selfhost',
    'providers':{'selfhost':'self-managed-postgresql','serverless':'supabase'},
    'migration':{'strategy':'async','single_writer':True}})
print('serverless boundary and data execution ownership passed')
PY
