path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["list", "read"]
}
path "kv/data/CICD/domains/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "kv/metadata/CICD/domains/*" {
  capabilities = ["list", "read"]
}
