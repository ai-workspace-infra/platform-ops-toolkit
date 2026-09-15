path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/data/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
path "kv/data/CICD/observability" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["list", "read"]
}
path "kv/metadata/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
path "kv/data/openclaw" {
  capabilities = ["read"]
}
path "kv/data/action-runner" {
  capabilities = ["read"]
}
path "kv/metadata/action-runner" {
  capabilities = ["list", "read"]
}
path "kv/data/CICD/domains/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "kv/metadata/CICD/domains/*" {
  capabilities = ["list", "read"]
}
path "kv/data/CICD/uat" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/uat" {
  capabilities = ["list", "read"]
}
path "kv/data/WEB_SAAS" {
  capabilities = ["read"]
}
path "kv/metadata/WEB_SAAS" {
  capabilities = ["list", "read"]
}
path "kv/data/uat/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "kv/metadata/uat/*" {
  capabilities = ["list", "read", "delete"]
}
