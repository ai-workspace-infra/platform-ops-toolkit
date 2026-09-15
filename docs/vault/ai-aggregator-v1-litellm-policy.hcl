# Render <env> as uat or prod before applying.
path "kv/data/<env>/ai-aggregator/database/litellm" {
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
