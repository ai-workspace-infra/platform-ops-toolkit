#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/actions/setup-deployment-runner/scripts/setup.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/input" "${workdir}/home"
ssh-keygen -q -t ed25519 -N '' -f "${workdir}/input/id_deploy"
key_b64="$(base64 <"${workdir}/input/id_deploy" | tr -d '\n')"

HOME="${workdir}/home" \
ACTION_SSH_KEY_B64="${key_b64}" \
ACTION_MATRIX_HOST='' \
ACTION_CMDB_FILE="${workdir}/cmdb.json" \
ACTION_WAIT_FOR_SSH=false \
ACTION_WAIT_FOR_PACKAGE_INIT=false \
ACTION_INSTALL_ANSIBLE=false \
ACTION_ASSERT_ANSIBLE_TARGET=false \
ACTION_ANSIBLE_INVENTORY="${workdir}/inventory.ini" \
bash "${script}"

test -f "${workdir}/home/.ssh/id_deploy"
mode="$(stat -c '%a' "${workdir}/home/.ssh/id_deploy" 2>/dev/null || stat -f '%Lp' "${workdir}/home/.ssh/id_deploy")"
test "${mode}" = 600
test "$(ssh-keygen -y -f "${workdir}/home/.ssh/id_deploy")" = "$(cat "${workdir}/input/id_deploy.pub")"

mkdir -p "${workdir}/bin"
printf '%s\n' '{"console-uat.onwalk.net":{"ip":"192.0.2.10","ansible_user":"admin"}}' >"${workdir}/cmdb.json"
cat >"${workdir}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${SSH_LOG}"
exit 0
EOF
chmod +x "${workdir}/bin/ssh"

PATH="${workdir}/bin:${PATH}" \
SSH_LOG="${workdir}/ssh.log" \
HOME="${workdir}/home" \
ACTION_SSH_KEY_B64="${key_b64}" \
ACTION_MATRIX_HOST=console-uat.onwalk.net \
ACTION_CMDB_FILE="${workdir}/cmdb.json" \
ACTION_WAIT_FOR_SSH=true \
ACTION_WAIT_FOR_PACKAGE_INIT=false \
ACTION_INSTALL_ANSIBLE=false \
ACTION_ASSERT_ANSIBLE_TARGET=false \
ACTION_ANSIBLE_INVENTORY="${workdir}/inventory.ini" \
bash "${script}"
grep -Fq 'admin@192.0.2.10 true' "${workdir}/ssh.log"

cat >"${workdir}/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${PYTHON_LOG}"
case "$*" in
  '-m pip install --help') printf '%s\n' '--break-system-packages' ;;
  '-m pip install --quiet --break-system-packages ansible hvac') ;;
  '-c import hvac') ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${workdir}/bin/python3"

PATH="${workdir}/bin:/usr/bin:/bin" \
PYTHON_LOG="${workdir}/python.log" \
HOME="${workdir}/home" \
ACTION_SSH_KEY_B64='' \
ACTION_MATRIX_HOST='' \
ACTION_CMDB_FILE="${workdir}/cmdb.json" \
ACTION_WAIT_FOR_SSH=false \
ACTION_WAIT_FOR_PACKAGE_INIT=false \
ACTION_INSTALL_ANSIBLE=true \
ACTION_ASSERT_ANSIBLE_TARGET=false \
ACTION_ANSIBLE_INVENTORY="${workdir}/inventory.ini" \
bash "${script}"
grep -Fxq -- '-m pip install --quiet --break-system-packages ansible hvac' "${workdir}/python.log"

echo "setup_deployment_runner_action_test: PASS"
