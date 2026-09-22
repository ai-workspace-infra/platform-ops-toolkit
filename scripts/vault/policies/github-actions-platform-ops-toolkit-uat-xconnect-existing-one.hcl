path "kv/data/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
path "kv/data/uat/xconnect-one" {
  capabilities = ["read"]
}
path "kv/data/prod/ulighthost-xconnect/observability.svc.plus" {
  capabilities = ["read"]
}
path "kv/data/uat/ulighthost-xconnect/*" {
  capabilities = ["read"]
}
path "kv/data/CICD/domains/svc.plus" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/domains/svc.plus" {
  capabilities = ["list", "read"]
}
path "kv/data/CICD/observability" {
  capabilities = ["read"]
}
