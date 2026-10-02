#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture"/.github/scripts/lib "$fixture"/scripts/pipeline/lib "$fixture/gitops/resources"
cp "$root/.github/scripts/lib/require-env.sh" "$fixture/.github/scripts/lib/require-env.sh"
cp "$root/.github/scripts/lib/require-env.sh" "$fixture/scripts/pipeline/lib/require-env.sh"
cp "$root/.github/scripts/lib/require-env.sh" "$fixture/playbooks-require-env.sh"
mkdir -p "$fixture/playbooks/scripts/pipeline/lib" "$fixture/gitops"
cp "$fixture/playbooks-require-env.sh" "$fixture/playbooks/scripts/pipeline/lib/require-env.sh"

git -C "$fixture/gitops" init -q
git -C "$fixture/gitops" config user.email test@example.invalid
git -C "$fixture/gitops" config user.name test
printf 'kind: Resource\n' >"$fixture/gitops/resources/example.yaml"
git -C "$fixture/gitops" add .
git -C "$fixture/gitops" commit -qm fixture

python3 "$root/scripts/ci/repository-conventions-verify.py" \
  --toolkit-root "$root" \
  --iac-root "$fixture" \
  --playbooks-root "$fixture/playbooks" \
  --gitops-root "$fixture/gitops"

printf '# changed\n' >>"$fixture/playbooks/scripts/pipeline/lib/require-env.sh"
if python3 "$root/scripts/ci/repository-conventions-verify.py" \
  --toolkit-root "$root" \
  --iac-root "$fixture" \
  --playbooks-root "$fixture/playbooks" \
  --gitops-root "$fixture/gitops"; then
  echo "expected require-env parity failure" >&2
  exit 1
fi

git -C "$fixture/gitops" checkout -q --orphan invalid-data
git -C "$fixture/gitops" rm -q -r . 2>/dev/null || true
printf '#!/usr/bin/env bash\n' >"$fixture/gitops/resources/not-data.sh"
git -C "$fixture/gitops" add .
git -C "$fixture/gitops" commit -qm invalid-data
cp "$fixture/playbooks-require-env.sh" "$fixture/playbooks/scripts/pipeline/lib/require-env.sh"
if python3 "$root/scripts/ci/repository-conventions-verify.py" \
  --toolkit-root "$root" \
  --iac-root "$fixture" \
  --playbooks-root "$fixture/playbooks" \
  --gitops-root "$fixture/gitops"; then
  echo "expected GitOps data-only failure" >&2
  exit 1
fi

echo "repository-conventions-verify: PASS"
