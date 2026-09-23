# Manually unseal shared Vault cluster nodes

Vault unseal is an operator task and is deliberately outside GitHub Actions.
The IaC pipeline may provision hosts and their network, but it must never read
or receive a Vault root token or unseal shares. Do not run `vault operator
init` on a node intended to join the existing Raft cluster.

## Operator connectivity

Run the helper from a shell on each host through the approved private operator
path: the PROD XConnect network, a cloud IAP/SSM console, or SSH over an
approved private route. Install [`vault-unseal-local.sh`](../../scripts/vault/vault-unseal-local.sh)
with owner `root` and mode `0700`. Transfer it through the same private path;
do not leave a world-readable copy on the host.

For a node reachable over SSH, the generic transfer pattern is:

```bash
export VAULT_NODE='vault-prod-0'
export SSH_TARGET='<operator-user>@<private-address-or-xconnect-name>'

scp scripts/vault/vault-unseal-local.sh "$SSH_TARGET:/tmp/vault-unseal-local.sh"
ssh "$SSH_TARGET" \
  'sudo install -o root -g root -m 0700 /tmp/vault-unseal-local.sh /usr/local/sbin/vault-unseal-local && rm -f /tmp/vault-unseal-local.sh'
```

Use the provider's private console/transfer mechanism instead if SSH is not the
approved access path. Do not enable public SSH only to install this helper.

## Node networking

`vault-prod-0` hosts the shared XConnect Gateway. `vault-prod-1` and
`vault-prod-2` are XConnect One members; they may reach the Gateway through NAT
egress or from their own public IPs. The only public inbound port is TCP 443
for the Caddy TLS entry `vault.svc.plus`. Vault 8200, SSH, monitoring, and
standalone XConnect ports remain private. XConnect must share the approved 443
entry or use an outbound tunnel to an approved relay. A public member IP is not
trusted by itself. If the Gateway is behind NAT without a reachable 443 entry
or outbound relay/rendezvous, members cannot connect to it.

## Unseal procedure

After verifying that a node joined the expected Raft cluster, run this on that
node:

```bash
sudo /usr/local/sbin/vault-unseal-local
```

Enter one authorized share at the hidden prompt. Repeat with separately held
shares until that node reports `sealed=false` and progress has reached its
threshold. Then connect to the next node and repeat; unseal state is per node.
The helper contacts only `127.0.0.1:8200`, reads one share without echo, sends
it directly to that node's `/v1/sys/unseal`, and does not persist it. It does
not accept a root token, read key files, or initialize a cluster.

Never concatenate shares into a variable/file or pass them as command-line
arguments. Do not store them as GitHub Actions secrets or variables.

Before moving `vault.svc.plus` or retiring any old peer, verify all intended
Raft peers, quorum, monitoring, backups, restore readiness, and TLS client
authentication.
