# Narrow shared Zero network bootstrap permissions for xconnect-zero-cloud.yaml.
path "kv/data/CICD/shared/xconnect" {
  capabilities = ["read"]
}
path "kv/data/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
# Per-network invitation is write-only from CI. No wildcard read is granted.
path "kv/data/CICD/shared/xconnect-operator-invite/*" {
  capabilities = ["create", "update"]
}
