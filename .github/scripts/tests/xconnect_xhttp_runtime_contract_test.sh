#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
helper="$repo_root/.github/scripts/xconnect-lab/verify-xhttp-runtime.sh"
test -x "$helper" || { echo 'XHTTP runtime verifier is not executable' >&2; exit 1; }

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/one/runtime/revisions/abc"

cat > "$tmp_dir/gateway.json" <<'JSON'
{"inbounds":[{"listen":"0.0.0.0","port":443,"protocol":"vless","streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{"rejectUnknownSni":true},"xhttpSettings":{"path":"/xconnect","mode":"auto","host":"tw-xconnect.svc.plus"}}}],"outbounds":[{"tag":"xconnect-wireguard","protocol":"freedom","settings":{"redirect":"127.0.0.1:51820"}}]}
JSON
cat > "$tmp_dir/one/runtime/active.json" <<JSON
{"xray_config_path":"$tmp_dir/one/runtime/revisions/abc/xray.json"}
JSON
cat > "$tmp_dir/one/runtime/revisions/abc/xray.json" <<'JSON'
{"inbounds":[{"listen":"127.0.0.1","port":51830,"protocol":"dokodemo-door","settings":{"network":"udp"}}],"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"tw-xconnect.svc.plus","port":443}]},"streamSettings":{"network":"xhttp","security":"tls","tlsSettings":{"serverName":"tw-xconnect.svc.plus"},"xhttpSettings":{"path":"/xconnect","mode":"auto","host":"tw-xconnect.svc.plus"}}}]}
JSON

"$helper" gateway "$tmp_dir/gateway.json" - tw-xconnect.svc.plus /xconnect auto tw-xconnect.svc.plus >/dev/null
"$helper" one "$tmp_dir/one" tw-xconnect.svc.plus tw-xconnect.svc.plus /xconnect auto tw-xconnect.svc.plus >/dev/null

if "$helper" gateway "$tmp_dir/gateway.json" - tw-xconnect.svc.plus /wrong auto tw-xconnect.svc.plus >/dev/null 2>&1; then
  echo 'Gateway verifier accepted an incorrect XHTTP path' >&2
  exit 1
fi
if "$helper" one "$tmp_dir/one" tw-xconnect.svc.plus tw-xconnect.svc.plus /xconnect auto wrong.example >/dev/null 2>&1; then
  echo 'One verifier accepted an incorrect XHTTP host' >&2
  exit 1
fi

echo 'xconnect_xhttp_runtime_contract_test: PASS'
