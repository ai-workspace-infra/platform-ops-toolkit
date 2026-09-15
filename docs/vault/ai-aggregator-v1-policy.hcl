# This is the short-lived deployment role policy used by Ansible. Render <env>
# as uat or prod before applying. Do not commit rendered policy files
# containing tokens; this file contains paths only. Service identities should
# use the narrower policies documented alongside this file.

path "kv/data/<env>/ai-aggregator/database/new-api" {
  capabilities = ["read"]
}

path "kv/data/<env>/ai-aggregator/database/litellm" {
  capabilities = ["read"]
}

path "kv/data/<env>/ai-aggregator/gateway/caddy" {
  capabilities = ["read"]
}

path "kv/data/<env>/ai-aggregator/gateway/new-api" {
  capabilities = ["read"]
}

path "kv/data/<env>/ai-aggregator/gateway/litellm" {
  capabilities = ["read"]
}

path "kv/data/<env>/ai-aggregator/litellm/providers/openai" {
  capabilities = ["read"]
}

path "kv/data/<env>/ai-aggregator/litellm/providers/anthropic" {
  capabilities = ["read"]
}

path "kv/data/<env>/ai-aggregator/litellm/providers/xai" {
  capabilities = ["read"]
}
