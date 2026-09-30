#!/usr/bin/env bash
set -euo pipefail

# The Daily UAT/PROD waits must only pass on an explicit child `success`, read
# status with the job token (not the 60-minute App token that dispatched), and
# survive transient API errors without failing a release the child completes.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
waiter="${repo_root}/.github/scripts/snapshots/wait-for-workflow-run.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

# Fake gh: each call consumes the next scripted response from RESPONSES
# ("fail" = API error, otherwise "<status>\t<conclusion>") and logs the token.
cat > "${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "${GH_TOKEN:-none}" "$*" >> "${GH_LOG}"
count="$(wc -l < "${GH_LOG}")"
response="$(sed -n "${count}p" "${RESPONSES}")"
[[ -n "${response}" ]] || response="$(tail -n 1 "${RESPONSES}")"
[[ "${response}" != fail ]] || { echo 'HTTP 502: Bad Gateway' >&2; exit 1; }
printf '%b\n' "${response}"
EOF
chmod +x "${workdir}/gh"

run_wait() {
  printf '%s\n' "$@" > "${workdir}/responses"
  : > "${workdir}/gh.log"
  GH_LOG="${workdir}/gh.log" RESPONSES="${workdir}/responses" PATH="${workdir}:${PATH}" \
    GH_TOKEN=app-token RUN_STATUS_TOKEN=job-token RUN_REPOSITORY=owner/repo \
    RUN_POLL_INTERVAL_SECONDS=1 RUN_MAX_READ_FAILURES="${MAX_FAILURES:-3}" \
    bash "${waiter}" "https://github.com/owner/repo/actions/runs/1001" "Test child" "${TIMEOUT:-20}"
}

# 1. Transient API errors recover; only the job token reads status.
run_wait fail fail 'in_progress\t' 'completed\tsuccess' > "${workdir}/out"
grep -Fq 'completed successfully' "${workdir}/out"
[[ "$(wc -l < "${workdir}/gh.log")" -eq 4 ]]
if grep -v '^job-token api repos/owner/repo/actions/runs/1001 ' "${workdir}/gh.log"; then
  echo 'Run status must be read with RUN_STATUS_TOKEN, never the dispatch App token.' >&2
  exit 1
fi

# 2. A child that completes without success fails the wait.
for conclusion in failure cancelled timed_out skipped ''; do
  if run_wait "completed\t${conclusion}" > /dev/null 2> "${workdir}/err"; then
    echo "A child concluded '${conclusion}' must not pass the wait." >&2
    exit 1
  fi
  grep -Fq 'completed with' "${workdir}/err"
done

# 3. Persistent unreadable status fails after the bounded budget.
if MAX_FAILURES=3 run_wait fail > /dev/null 2> "${workdir}/err"; then
  echo 'Persistently unreadable status must fail the wait.' >&2
  exit 1
fi
grep -Fq 'unreadable 3 times in a row' "${workdir}/err"
[[ "$(wc -l < "${workdir}/gh.log")" -eq 3 ]]

# 4. A child that never finishes fails at the timeout.
if TIMEOUT=2 run_wait 'in_progress\t' > /dev/null 2> "${workdir}/err"; then
  echo 'A child that never finishes must time out.' >&2
  exit 1
fi
grep -Fq 'Timed out waiting' "${workdir}/err"

# 5. An unknown status or an unparsable run reference fails closed.
if run_wait 'mystery\t' > /dev/null 2> "${workdir}/err"; then
  echo 'An unexpected run status must fail the wait.' >&2
  exit 1
fi
if GH_TOKEN=app-token RUN_REPOSITORY=owner/repo PATH="${workdir}:${PATH}" \
    bash "${waiter}" "https://github.com/owner/repo/actions/runs/not-a-run" "Test child" 5 > /dev/null 2>&1; then
  echo 'An unparsable run reference must fail the wait.' >&2
  exit 1
fi

echo "daily_snapshot_run_wait_test: PASS"
