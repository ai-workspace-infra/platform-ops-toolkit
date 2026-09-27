# The standalone Observability pipeline needs only the shared deployment key
# and DNS token from the root CICD secret. Keep it out of the general UAT role,
# which can read and write broader UAT application secrets.
path "kv/data/CICD" {
  capabilities = ["read"]
}
