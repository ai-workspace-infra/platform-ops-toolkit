# The shared Observability service stage only needs the GCP WIF identity for
# open-platform-shared. Terraform state, Vault application data, deployment
# keys, and DNS credentials remain unavailable to this role.
path "kv/data/shared/platform/oidc/open-platform-shared" {
  capabilities = ["read"]
}

path "kv/metadata/shared/platform/oidc/open-platform-shared" {
  capabilities = ["read"]
}
