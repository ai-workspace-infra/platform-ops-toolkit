#!/bin/bash
PLAN="${INPUT_INSTANCE_PLAN:-${INPUT_INSTANCE_PLAN_____4C8G_:-}}"
DOMAIN="${INPUT_DOMAIN_____ALL_}"
PROVIDER="${INPUT_CLOUD_PROVIDER:-vultr-vps}"

case "${PLAN}" in
  1C2G|2C4G|4C8G) ;;
  *)
    echo "::error::Unsupported instance_plan='${PLAN}'. Expected 1C2G, 2C4G, or 4C8G." >&2
    exit 1
    ;;
esac

# agent-proxy 默认使用 1C2G
if [ "$DOMAIN" == "agent-proxy" ] && [ "$PLAN" == "4C8G" ]; then
  PLAN="1C2G"
fi

if [ "$PROVIDER" == "aws-cloud" ]; then
  if [ "$PLAN" == "1C2G" ]; then
    echo "api=t4g.small" >> "$GITHUB_OUTPUT"
  elif [ "$PLAN" == "2C4G" ]; then
    echo "api=t4g.medium" >> "$GITHUB_OUTPUT"
  else
    echo "api=t4g.large" >> "$GITHUB_OUTPUT"
  fi
else
  # 默认 vultr-vps
  if [ "$PLAN" == "1C2G" ]; then
    echo "api=vc2-1c-2gb" >> "$GITHUB_OUTPUT"
  elif [ "$PLAN" == "2C4G" ]; then
    echo "api=vc2-2c-4gb" >> "$GITHUB_OUTPUT"
  else
    echo "api=vc2-4c-8gb" >> "$GITHUB_OUTPUT"
  fi
fi
