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
path "kv/data/CICD/sit" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/sit" {
  capabilities = ["list", "read"]
}
path "kv/data/CICD/sit/iac_state" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/sit/iac_state" {
  capabilities = ["read"]
}
path "kv/data/CICD/sit/ucloud/*" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/sit/ucloud/*" {
  capabilities = ["list", "read"]
}
path "kv/data/sit/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "kv/metadata/sit/*" {
  capabilities = ["list", "read", "delete"]
}
