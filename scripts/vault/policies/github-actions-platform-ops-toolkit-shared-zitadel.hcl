# Service delivery only. No Terraform state, DNS or migration-source access.
path "kv/data/shared/platform/oidc/open-platform-shared" {
  capabilities = ["read"]
}
path "kv/data/shared/iam" {
  capabilities = ["read"]
}
path "kv/data/shared/databases" {
  capabilities = ["read"]
}
