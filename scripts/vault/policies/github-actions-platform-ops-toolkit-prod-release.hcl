# Release authoring only; downstream deployments use their own scoped roles.
path "kv/data/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
