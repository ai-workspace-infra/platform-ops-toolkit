path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/data/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
path "kv/data/CICD/observability" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["list", "read"]
}
path "kv/metadata/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
path "kv/data/openclaw" {
  capabilities = ["read"]
}
path "kv/data/action-runner" {
  capabilities = ["read"]
}
path "kv/metadata/action-runner" {
  capabilities = ["list", "read"]
}
path "kv/data/CICD/uat" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/uat" {
  capabilities = ["list", "read"]
}
# Terraform state is stored below the environment prefix. Vault evaluates
# child paths independently, so the parent read permission above does not
# authorize this concrete KV v2 data path.
path "kv/data/CICD/uat/iac_state" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/uat/iac_state" {
  capabilities = ["read"]
}
path "kv/data/CICD/domains/svc.plus" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/domains/svc.plus" {
  capabilities = ["list", "read"]
}
path "kv/data/uat/xconnect-one" {
  capabilities = ["read"]
}
path "kv/metadata/uat/xconnect-one" {
  capabilities = ["list", "read"]
}
path "kv/data/uat/serverless/cloudflare" {
  capabilities = ["read"]
}
path "kv/metadata/uat/serverless/cloudflare" {
  capabilities = ["list", "read"]
}
path "kv/data/uat/ulighthost-xconnect/tw-xconnect.onwalk.net" {
  capabilities = ["read"]
}
path "kv/metadata/uat/ulighthost-xconnect/tw-xconnect.onwalk.net" {
  capabilities = ["list", "read"]
}
path "kv/data/prod/ulighthost-xconnect/tw-xconnect.svc.plus" {
  capabilities = ["read"]
}
path "kv/metadata/prod/ulighthost-xconnect/tw-xconnect.svc.plus" {
  capabilities = ["list", "read"]
}
