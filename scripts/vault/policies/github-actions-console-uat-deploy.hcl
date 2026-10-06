# Console UAT deployment only. No shared CICD, database, PROD or KV writes.
path "kv/data/uat/serverless/cloudflare" {
  capabilities = ["read"]
}
