path "kv/data/CICD/shared/gcp-bootstrap/open-platform-shared" {
  capabilities = ["read", "create", "update"]
}

path "kv/metadata/CICD/shared/gcp-bootstrap/open-platform-shared" {
  capabilities = ["read", "delete"]
}

path "kv/data/CICD/shared/iac_state" {
  capabilities = ["read"]
}

path "kv/metadata/CICD/shared/iac_state" {
  capabilities = ["read"]
}

path "kv/data/shared/platform/oidc/open-platform-shared" {
  capabilities = ["create", "update"]
}

path "kv/metadata/shared/platform/oidc/open-platform-shared" {
  capabilities = ["read"]
}
