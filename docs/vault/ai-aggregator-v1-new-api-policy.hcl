# Render <env> as uat or prod before applying.
path "kv/data/<env>/ai-aggregator/database/new-api" {
  capabilities = ["read"]
}

path "kv/data/<env>/ai-aggregator/gateway/new-api" {
  capabilities = ["read"]
}
