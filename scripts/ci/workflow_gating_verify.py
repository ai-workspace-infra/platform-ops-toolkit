#!/usr/bin/env python3
"""Assert that job gating in .github/workflows/*.yaml is falsifiable.

Every check here corresponds to a defect this repository actually shipped, each
of which presented as a permanently `skipped` job rather than as an error. That
is the whole point: a broken gate is invisible in the run summary, so it has to
be caught by an assertion instead of by review.

  C1  folded-scalar `if:` that swallows the expression
  C2  skip propagating past a guarded job into a downstream job without a guard
      (a guard is always() or !cancelled() -- they are equivalent here)
  C3  a guard without a result assertion on each upstream
  C4  needs.<x> referenced in an `if:` but not declared in needs:
  C5  a script invoked bare from `run:` without the exec bit set in git

Exit 0 = all pass. Non-zero = at least one violation, listed on stderr.
"""

import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"

violations = []


def git_file_modes():
    """Map repo-relative path -> git mode. The mode in the index is what the
    runner checks out; a local chmod that was never staged does not travel."""
    out = subprocess.run(
        ["git", "ls-files", "-s"], cwd=REPO_ROOT,
        capture_output=True, text=True, check=True).stdout
    modes = {}
    for line in out.splitlines():
        meta, _, path = line.partition("\t")
        modes[path] = meta.split()[0]
    return modes


# A bare invocation is a script path in *command* position. `bash x.sh` runs
# fine without the exec bit, so only the leading token of each command segment
# is interesting -- which is easier to get right by splitting than by one regex.
EXPR = re.compile(r"\$\{\{[^}]*\}\}")
SEGMENT = re.compile(r"[\n;]|&&|\|\||\|")
INTERPRETERS = {"bash", "sh", "zsh", "source", ".", "exec",
                "python", "python3", "env", "sudo"}


def script_ref(token):
    """Repo-relative path if the token names a script in this repo, else None."""
    token = token.strip("\"'")
    for marker in (".github/scripts/", "scripts/"):
        i = token.find(marker)
        if i != -1:
            return token[i:]
    return None


def bare_invocations(block):
    block = EXPR.sub("EXPR", block)          # ${{ x }} holds spaces; collapse it
    for segment in SEGMENT.split(block):
        tokens = segment.split()
        if not tokens:
            continue
        head = tokens[0]
        if head in INTERPRETERS or head.startswith("-") or "=" in head:
            continue
        if not head.endswith((".sh", ".py")):
            continue
        rel = script_ref(head)
        if rel:
            yield rel


def iter_run_blocks(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "run" and isinstance(v, str):
                yield v
            else:
                yield from iter_run_blocks(v)
    elif isinstance(node, list):
        for item in node:
            yield from iter_run_blocks(item)


# always() and !cancelled() are the same thing for skip propagation: both make
# the job evaluate its own `if` instead of inheriting an upstream skip. Treating
# only always() as a guard is how a real regression slipped through -- PR #116
# swapped every always() for !cancelled(), this check went on reporting OK, and
# #117 then deleted the guard from deploy_base with nothing left to catch it.
def has_guard(cond):
    return "always()" in cond or "cancelled()" in cond


def report(wf, job, check, msg):
    violations.append(f"{wf}: job `{job}`: [{check}] {msg}")


def check_workflow(path, modes):
    doc = yaml.safe_load(path.read_text())
    if not isinstance(doc, dict):
        return
    jobs = doc.get("jobs") or {}
    wf = path.name

    # C5 -- a bare-invoked script without the exec bit dies with exit 126
    # "Permission denied" before emitting a single line, so the log shows the
    # step's env block and nothing else. This is only reachable once the step
    # actually runs: two such scripts sat in deploy_base for as long as that
    # job was being skipped (#90, #93).
    seen = set()
    for block in iter_run_blocks(doc):
        for rel in bare_invocations(block):
            if rel in seen:
                continue
            seen.add(rel)
            mode = modes.get(rel)
            if mode is None:
                violations.append(
                    f"{wf}: [C5] `run:` invokes {rel}, which is not tracked in git")
            elif not mode.endswith("755"):
                violations.append(
                    f"{wf}: [C5] `run:` invokes {rel} bare, but its git mode is "
                    f"{mode} -- the step will exit 126 Permission denied "
                    f"(fix: git update-index --chmod=+x {rel})")

    for name, cfg in jobs.items():
        if not isinstance(cfg, dict):
            continue
        cond = cfg.get("if")
        needs = cfg.get("needs") or []
        if isinstance(needs, str):
            needs = [needs]
        if cond is None:
            continue
        cond = str(cond)

        # C1 -- A folded scalar (`if: >-`) keeps a newline for every line
        # indented deeper than the first content line. The result is a string
        # containing "${{\n ... \n}}", which GitHub never evaluates as an
        # expression: it is truthy text, or falsy, but never the condition you
        # wrote. Keep every operand at one uniform indent.
        if cond.lstrip().startswith("${{") and "\n" in cond.strip():
            report(wf, name, "C1",
                   "`if:` folded scalar contains newlines inside ${{ }}; "
                   "indent every continuation line to the same column as the first")

        refs = set(re.findall(r"needs\.([A-Za-z0-9_-]+)\.", cond))

        if needs:
            # C2 -- A skipped job propagates its skip down the entire needs
            # chain. always() stops it only for the job carrying it, so a job
            # downstream of an always() job is skipped before its own `if` is
            # ever evaluated -- however correct that `if` may be.
            if not has_guard(cond):
                upstream_always = [
                    u for u in needs
                    if isinstance(jobs.get(u), dict) and has_guard(str(jobs[u].get("if", "")))
                ]
                if upstream_always:
                    report(wf, name, "C2",
                           f"needs {', '.join(upstream_always)} which run(s) under a guard, "
                           f"but this job's `if:` has no always()/!cancelled() -- it will be skipped "
                           f"without its condition ever being evaluated")

            # C3 -- always() also disables the implicit "upstream succeeded"
            # guard, so each upstream result has to be asserted explicitly or
            # the job runs after a real failure.
            # `!failure()` is job-level: it is false if ANY needs job failed, so
            # it asserts every upstream at once and makes per-job result checks
            # redundant. Demanding them anyway would push authors toward
            # deleting the guard instead -- which is the defect this file exists
            # to catch.
            if has_guard(cond) and "failure()" not in cond:
                unasserted = [u for u in needs if u not in refs]
                if unasserted:
                    report(wf, name, "C3",
                           f"uses a guard but never checks needs.<job>.result for: "
                           f"{', '.join(unasserted)} -- it would run after those fail")

        # C4 -- needs.<x> for a job absent from needs: evaluates to empty, so
        # the comparison is false and the job is skipped forever, silently.
        for ref in sorted(refs):
            if ref not in needs:
                report(wf, name, "C4",
                       f"`if:` reads needs.{ref}.* but `{ref}` is not in needs: "
                       f"-- it resolves to empty, making the condition permanently false")
            elif ref not in jobs:
                report(wf, name, "C4",
                       f"`if:` reads needs.{ref}.* but no job `{ref}` is defined")


def main():
    paths = sorted(p for p in WORKFLOW_DIR.iterdir()
                   if p.suffix in (".yaml", ".yml"))
    if not paths:
        sys.exit(f"no workflows found under {WORKFLOW_DIR}")

    modes = git_file_modes()
    for path in paths:
        check_workflow(path, modes)

    if violations:
        print(f"FAIL: {len(violations)} gating violation(s)", file=sys.stderr)
        for v in violations:
            print(f"  {v}", file=sys.stderr)
        return 1

    print(f"OK: job gating verified across {len(paths)} workflow(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
