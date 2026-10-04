#!/usr/bin/env python3
"""Resolve the required migration version from the checked-out release tag."""
import argparse
import re
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, required=True)
parser.add_argument("--tag", required=True)
args = parser.parse_args()
if not re.fullmatch(r"(?:uat-)?daily-build-\d{4}\.\d{2}\.\d{2}(?:-r[1-9]\d*)?|v\d[0-9.r-]*", args.tag):
    raise SystemExit("BLOCKED: Accounts upgrade target must be an immutable release tag")

def git(*parts):
    return subprocess.check_output(["git", "-C", str(args.source), *parts], text=True).strip()

source_sha = git("rev-parse", "HEAD")
if git("rev-parse", f"refs/tags/{args.tag}^{{commit}}") != source_sha:
    raise SystemExit("BLOCKED: Accounts checkout does not match the deployment tag")
versions = []
for path in (args.source / "sql/migrations").glob("*.up.sql"):
    match = re.fullmatch(r"([1-9][0-9]*)_.+\.up\.sql", path.name)
    if not match:
        raise SystemExit("BLOCKED: unrecognized Accounts migration filename")
    versions.append(int(match[1]))
if not versions or len(versions) != len(set(versions)):
    raise SystemExit("BLOCKED: missing or duplicate Accounts migration versions")
print(f"EXPECTED_ACCOUNTS_SCHEMA_VERSION={max(versions)}")
print(f"ACCOUNTS_UPGRADE_SOURCE_SHA={source_sha}")
