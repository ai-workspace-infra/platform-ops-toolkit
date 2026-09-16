path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["read"]
}
path "kv/data/CICD/prod/gcp-bootstrap/xworktech" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/prod/gcp-bootstrap/xworktech" {
  capabilities = ["read"]
}
path "kv/data/CICD/prod/iac_state" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/prod/iac_state" {
  capabilities = ["read"]
}
path "kv/data/prod/platform/oidc/xworktech" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/prod/platform/oidc/xworktech" {
  capabilities = ["read"]
}
