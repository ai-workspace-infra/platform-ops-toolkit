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
path "kv/data/CICD/prod" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/prod" {
  capabilities = ["list", "read"]
}
path "kv/data/CICD/prod/iac_state" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/prod/iac_state" {
  capabilities = ["read"]
}
path "kv/data/WEB_SAAS" {
  capabilities = ["read"]
}
path "kv/metadata/WEB_SAAS" {
  capabilities = ["list", "read"]
}
path "kv/data/prod/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "kv/metadata/prod/*" {
  capabilities = ["list", "read"]
}
