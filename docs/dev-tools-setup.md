# Development Tools Setup

本文记录本机用于发布、基础设施和 Cloudflare/Supabase 运维的 CLI 工具安装方式。

## Tooling status

| Tool | CLI | Recommended installation | Current status |
|---|---|---|---|
| GitHub | `gh` | Homebrew | Installed: `2.98.0` |
| Google Cloud | `gcloud` | Homebrew cask | Installed, blocked by Python 3.9 runtime |
| Cloudflare | `wrangler` | npm global package | Installed: `4.127.1` |
| Supabase | `supabase` | Homebrew tap | Installed: `2.116.0` |
| Go runtime | `go` | Go toolchain | Available: `go1.26.4 darwin/arm64` |
| Next.js MCP | MCP server | Codex app/plugin | Not connected |
| Browser MCP | MCP server | Codex Browser skill | Available in current Codex session |
| Go MCP | MCP server | Codex app/plugin | Not connected |
| Vault MCP | MCP server | Codex app/plugin | Not connected |

The GitHub CLI is installed only through Homebrew at `/opt/homebrew/bin/gh`.
The previous manually installed copy at `/Users/shenlan/bin/gh` was removed.

## Homebrew environment

On Apple Silicon macOS, initialize Homebrew in the current shell:

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"
```

To make this persistent for zsh:

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
```

## Installation

```bash
brew install gh
brew install --cask google-cloud-sdk
npm install --global wrangler
brew install supabase/tap/supabase
```

If a download times out, rerun the individual command. Do not place manually downloaded
binaries in `/Users/shenlan/bin`.

The verified Google Cloud CLI is currently under the Homebrew cask staging directory, but it
cannot start because the active Python is 3.9. Configure `CLOUDSDK_PYTHON` to a supported Python
3.10–3.14 interpreter, or reinstall/link the cask after installing a supported interpreter.

## Verification

```bash
gh --version
gcloud --version
wrangler --version
supabase --version
go version
```

Authenticate only when required:

```bash
gh auth login
gcloud auth login
npx wrangler login
supabase login
```

Never commit access tokens, service-account keys, API keys, or database connection strings.
Production credentials must be read at runtime from Vault and must not be passed as workflow
inputs or printed in logs.

## Verified MCP status

CLI installation does not automatically enable MCP servers. The current verification found:

| MCP capability | Status |
|---|---|
| Browser MCP | Connected and available in the current Codex session |
| Next.js MCP | Not connected |
| Go MCP | Not connected |
| Vault MCP | Not connected |
| Cloudflare MCP | Not connected |
| Supabase MCP | Not connected |

Cloudflare, Supabase, Next.js, Go, and Vault MCP access requires the corresponding Codex
app/plugin to be installed and connected to the intended account. Verify the connection before
using it; a CLI version check is not evidence that an MCP server is enabled.

MCP connections must use the smallest required scope, avoid exposing Vault tokens or production
credentials, and keep production DNS cutover as a separately approved manual operation.

## Next.js, Browser, and Go MCP

These are MCP capabilities, not replacements for the local CLIs:

- **Next.js MCP**: use for inspecting or assisting a Next.js application. It requires the
  corresponding MCP server/app connection and should be scoped to the intended project.
- **Browser MCP**: the Codex Browser skill is available in this session for visible-page
  navigation and inspection. Browser authentication state and cookies must not be extracted.
- **Go MCP**: a Go runtime is available, but that does not mean a Go MCP server is connected.
  Enable a Go MCP only when its tool manifest and project scope are confirmed.
- **Vault MCP**: use only for explicitly scoped Vault inspection or operations. Production
  secret values, admin tokens, and OIDC credentials must never be copied into chat, committed,
  or printed in logs.

Before using any MCP, verify its connection in Codex. Do not add guessed server URLs, tokens, or
local configuration paths to this repository.
