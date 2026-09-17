path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/data/CICD/*" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["list", "read"]
}
path "kv/metadata/CICD/*" {
  capabilities = ["list", "read"]
}
