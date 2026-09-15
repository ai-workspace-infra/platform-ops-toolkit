# Render <env> as uat or prod before applying.
path "kv/data/<env>/ai-aggregator/gateway/caddy" {
  capabilities = ["read"]
}
