#!/usr/bin/env bash
set -euo pipefail

role="${1:?role is required}"
path="${2:?config path or state directory is required}"
remote_address="${3:?remote address is required}"
server_name="${4:?server name is required}"
xhttp_path="${5:?XHTTP path is required}"
xhttp_mode="${6:?XHTTP mode is required}"
xhttp_host="${7:?XHTTP host is required}"

if [[ "$role" == one ]]; then
  active="$path/runtime/active.json"
  config_path=$(jq -er '.xray_config_path' "$active")
  jq -e \
    --arg address "$remote_address" \
    --arg server_name "$server_name" \
    --arg path "$xhttp_path" \
    --arg mode "$xhttp_mode" \
    --arg host "$xhttp_host" \
    '
      (.inbounds | any(.[];
        .listen == "127.0.0.1" and
        .port == 51830 and
        .protocol == "dokodemo-door" and
        .settings.network == "udp"
      )) and
      (.outbounds | any(.[];
        .protocol == "vless" and
        .settings.vnext[0].address == $address and
        .settings.vnext[0].port == 443 and
        .streamSettings.network == "xhttp" and
        .streamSettings.security == "tls" and
        .streamSettings.tlsSettings.serverName == $server_name and
        .streamSettings.xhttpSettings.path == $path and
        .streamSettings.xhttpSettings.mode == $mode and
        .streamSettings.xhttpSettings.host == $host
      ))
    ' "$config_path" >/dev/null
  echo "xhttp_runtime=valid role=one config=$config_path local_udp=127.0.0.1:51830 remote=$remote_address:443"
elif [[ "$role" == gateway ]]; then
  config_path="$path"
  jq -e \
    --arg server_name "$server_name" \
    --arg path "$xhttp_path" \
    --arg mode "$xhttp_mode" \
    --arg host "$xhttp_host" \
    '
      (.inbounds | any(.[];
        .listen == "0.0.0.0" and
        .port == 443 and
        .protocol == "vless" and
        .streamSettings.network == "xhttp" and
        .streamSettings.security == "tls" and
        .streamSettings.tlsSettings.rejectUnknownSni == true and
        .streamSettings.xhttpSettings.path == $path and
        .streamSettings.xhttpSettings.mode == $mode and
        .streamSettings.xhttpSettings.host == $host
      )) and
      (.outbounds | any(.[];
        .tag == "xconnect-wireguard" and
        .protocol == "freedom" and
        .settings.redirect == "127.0.0.1:51820"
      ))
    ' "$config_path" >/dev/null
  echo "xhttp_runtime=valid role=gateway config=$config_path public_tcp=443 local_wireguard=127.0.0.1:51820"
else
  echo "unsupported runtime role: $role" >&2
  exit 2
fi
