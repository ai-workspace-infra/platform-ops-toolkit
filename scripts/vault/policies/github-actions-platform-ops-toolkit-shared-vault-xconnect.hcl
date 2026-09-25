# Shared Vault XConnect enrollment (vault-server.yml xconnect-* stages).
# Zero service credentials and the transport id for the shared network.
path "kv/data/CICD/shared/xconnect" {
  capabilities = ["read"]
}
# Wildcard svc.plus TLS: the Gateway frontend certificate and the public
# trust bundle handed to One nodes.
path "kv/data/CICD/domains/svc.plus" {
  capabilities = ["read"]
}
# GitHub App key used only to mint a read-only token for the private
# XConnect-One / XConnect-Gateway release downloads.
path "kv/data/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
# C5: CI stores the operator device's one-use invitation here; it cannot
# read it back. The operator reads it with their own Vault login.
path "kv/data/CICD/shared/xconnect-operator-invite" {
  capabilities = ["create", "update"]
}
