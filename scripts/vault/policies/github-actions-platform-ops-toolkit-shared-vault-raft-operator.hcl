path "sys/storage/raft/configuration" {
  capabilities = ["read"]
}
path "sys/step-down" {
  capabilities = ["update", "sudo"]
}
path "sys/storage/raft/remove-peer" {
  capabilities = ["update", "sudo"]
}
