path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["read"]
}
path "kv/data/CICD/uat/gcp-bootstrap/xworktech" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/uat/gcp-bootstrap/xworktech" {
  capabilities = ["read"]
}
path "kv/data/CICD/uat/iac_state" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/uat/iac_state" {
  capabilities = ["read"]
}
path "kv/data/uat/platform/oidc/xworktech" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/uat/platform/oidc/xworktech" {
  capabilities = ["read"]
}
