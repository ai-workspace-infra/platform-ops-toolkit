#!/usr/bin/env python3
"""
UAT Serverless 自动化调度控制器 (deploy_orchestrator.py)

功能:
1. 从 https://vault.svc.plus (路径: kv/data/<env>/serverless/*) 集中拉取 Cloudflare, GCP, Supabase 认证信息
2. 调度执行 Cloud Run 后端容器部署 (accounts, billing-service, content-service, 默认 0 副本)
3. 调度执行 Cloudflare Worker (edge-gateway) 与 Cloudflare Pages (portal) 部署
4. 运行端到端健康与可用性冒烟检查 (Smoke Test)
"""

import json
import os
import subprocess
import sys
import urllib.request
import urllib.error
from urllib.parse import quote, urlsplit, unquote

VAULT_ADDR = os.environ.get("VAULT_ADDR", "https://vault.svc.plus").rstrip("/")
VAULT_TOKEN = os.environ.get("VAULT_TOKEN", "")
VAULT_ENV_PATH = os.environ.get("VAULT_ENV_PATH", os.environ.get("DEPLOY_ENV", "uat")).strip()
if VAULT_ENV_PATH not in {"dev", "sit", "uat", "prod"}:
    raise SystemExit("VAULT_ENV_PATH/DEPLOY_ENV must be one of: dev, sit, uat, prod")
SERVERLESS_BASE_PATH = os.environ.get(
    "VAULT_SERVERLESS_PATH", f"kv/data/{VAULT_ENV_PATH}/serverless"
).strip().rstrip("/")
DEPLOY_CLOUDFLARE = os.environ.get("DEPLOY_CLOUDFLARE", "true").lower() == "true"
DEPLOY_EDGE_WORKER = os.environ.get("DEPLOY_EDGE_WORKER", "false").lower() == "true"
DEPLOY_CLOUD_RUN = os.environ.get("DEPLOY_CLOUD_RUN", "true").lower() == "true"
VERIFY_SUPABASE = os.environ.get("VERIFY_SUPABASE", "true").lower() == "true"
CLOUD_RUN_SERVICE = os.environ.get("CLOUD_RUN_SERVICE", "").strip()
CLOUDFLARE_TARGET = os.environ.get("CLOUDFLARE_TARGET", "").strip()
CLOUDFLARE_BOUNDARY_CONFIG = os.environ.get("CLOUDFLARE_BOUNDARY_CONFIG", "").strip()
GITOPS_OAUTH_GITHUB_CONFIG = os.environ.get("GITOPS_OAUTH_GITHUB_CONFIG", "").strip()

def log(msg: str):
    print(f"==> [UAT Orchestrator] {msg}", flush=True)

def fetch_vault_secret(subpath: str) -> dict:
    return fetch_vault_path(f"{SERVERLESS_BASE_PATH}/{subpath}")

def fetch_vault_path(path: str) -> dict:
    if not VAULT_TOKEN:
        log(f"Warning: VAULT_TOKEN not set, skipping Vault fetch for {path}")
        return {}
    url = f"{VAULT_ADDR}/v1/{path.lstrip('/')}"
    req = urllib.request.Request(url, headers={"X-Vault-Token": VAULT_TOKEN})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("data", {}).get("data", {}) or data.get("data", {})
    except Exception as e:
        log(f"Failed to fetch Vault secret at {url}: {e}")
        return {}


def resolve_github_oauth_runtime() -> dict:
    """Resolve the enabled GitHub OAuth contract for the target environment.

    The client id and redirect/frontend URLs are non-sensitive GitOps metadata;
    only ``client_secret`` is read from the environment-scoped Vault path. Do
    not let an accounts deployment continue with an empty provider: that makes
    the service start successfully but returns ``provider_not_found`` at login.
    """
    if not GITOPS_OAUTH_GITHUB_CONFIG:
        raise SystemExit(
            "GITOPS_OAUTH_GITHUB_CONFIG is required for an accounts deployment"
        )

    try:
        with open(GITOPS_OAUTH_GITHUB_CONFIG, encoding="utf-8") as handle:
            metadata = json.load(handle)
    except (OSError, ValueError) as exc:
        raise SystemExit(
            f"Unable to read GitOps GitHub OAuth metadata at {GITOPS_OAUTH_GITHUB_CONFIG}: {exc}"
        ) from exc

    if not isinstance(metadata, dict):
        raise SystemExit("GitOps GitHub OAuth metadata must be a JSON object")
    if metadata.get("enabled") is not True:
        raise SystemExit("GitHub OAuth must be enabled in GitOps before deploying accounts")

    client_id = str(metadata.get("client_id", "")).strip()
    redirect_url = str(metadata.get("redirect_url", "")).strip()
    frontend_url = str(metadata.get("frontend_url", "")).strip()
    secret_path = str(metadata.get("vault_secret_path", "")).strip()
    secret_key = str(metadata.get("vault_secret_key", "client_secret")).strip()
    expected_path = f"kv/data/{VAULT_ENV_PATH}/accounts/oauth/github"

    if not client_id:
        raise SystemExit("GitOps GitHub OAuth metadata must contain client_id")
    if not redirect_url:
        raise SystemExit("GitOps GitHub OAuth metadata must contain redirect_url")
    if not frontend_url:
        raise SystemExit("GitOps GitHub OAuth metadata must contain frontend_url")
    if secret_path != expected_path:
        raise SystemExit(
            f"GitHub OAuth Vault path must be {expected_path}; got {secret_path or '<empty>'}"
        )
    if not secret_key:
        raise SystemExit("GitOps GitHub OAuth metadata must contain vault_secret_key")

    secret_data = fetch_vault_path(secret_path)
    client_secret = str(secret_data.get(secret_key, "")).strip()
    if not client_secret:
        raise SystemExit(
            f"Vault GitHub OAuth secret is missing {secret_key} at {secret_path}"
        )

    return {
        "GITHUB_CLIENT_ID": client_id,
        "GITHUB_CLIENT_SECRET": client_secret,
        "OAUTH_FRONTEND_URL": frontend_url,
        "OAUTH_GITHUB_REDIRECT_URL": redirect_url,
    }


def billing_secret(secrets: dict, key: str) -> str:
    """Resolve the environment-prefixed Vault billing key at the boundary."""
    prefix = "PROD" if VAULT_ENV_PATH == "prod" else "SANDBOX"
    return str(secrets.get(f"{prefix}_{key}", secrets.get(key, ""))).strip()


def resolve_console_origins(config_path: str) -> list:
    """Return the browser origins that accounts must accept for CORS.

    The portal is served from the console host, so that host is the Origin
    every login request carries. Aliases that resolve to the same host are
    included as well: a user who reaches the console through the canonical
    alias sends the alias as the Origin, not the target.

    Deriving this from the GitOps EdgeRoutingConfig is deliberate. The same
    knowledge previously lived only in the accounts config template, and a new
    environment shipped without it -- every browser login was rejected with an
    empty 403 by the CORS middleware while curl probes without an Origin header
    kept returning a normal 401.
    """
    if not config_path:
        return []
    try:
        with open(config_path, encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError) as exc:
        log(f"Failed to read routing config at {config_path}: {exc}")
        return []

    spec = document.get("spec", {}) or {}
    console_host = str((spec.get("serverless", {}) or {}).get("console_host", "")).strip()
    if not console_host:
        return []

    hosts = [console_host]

    routing = ((spec.get("runtime", {}) or {}).get("routing", {}) or {})
    canonical = ((routing.get("dns", {}) or {}).get("canonical_records", {}) or {})
    for alias, target in canonical.items():
        if str(target).strip() == console_host:
            hosts.append(str(alias).strip())

    for alias, targets in (spec.get("domains", {}) or {}).items():
        if not isinstance(targets, dict):
            continue
        if str(targets.get("serverless", "")).strip() == console_host:
            hosts.append(str(alias).strip())

    # Hostnames that still reach the console but are not part of the canonical
    # alias contract -- an older Worker custom domain that stayed bound, for
    # example. The browser sends whichever hostname the user typed as the
    # Origin, so a host that answers has to be on the allowlist or its logins
    # fail with an empty 403 that the UI reports as a generic error.
    for alias in ((spec.get("serverless", {}) or {}).get("console_aliases", []) or []):
        hosts.append(str(alias).strip())

    origins = []
    for host in hosts:
        if not host:
            continue
        origin = host if "://" in host else f"https://{host}"
        if origin not in origins:
            origins.append(origin)
    return origins


def normalize_runtime_database_uri(secrets: dict) -> str:
    """Return a URL-safe Supabase runtime URI.

    Vault may contain a pooler URI whose password was copied without URL
    encoding. Rebuild the user-info from the discrete Vault fields so special
    characters in the password cannot make the Go services reject the URI.
    """
    raw = str(
        secrets.get(
            "SUPABASE_CONNECT_URI",
            secrets.get(
                "DATABASE_SESSION_POOLER_URL",
                secrets.get("DATABASE_POOLER_URL", secrets.get("DATABASE_DIRECT_URL", "")),
            ),
        )
    ).strip()
    password = str(secrets.get("DATABASE_PASSWORD", "")).strip()
    if not raw or "://" not in raw or "@" not in raw:
        return raw
    if not password:
        password = unquote(urlsplit(raw).password or "")
    if not password:
        return raw

    scheme, authority_path = raw.split("://", 1)
    userinfo, host_path = authority_path.rsplit("@", 1)
    username = str(secrets.get("DATABASE_USERNAME", "")).strip()
    if not username:
        username = userinfo.rsplit(":", 1)[0]
    if not username:
        return raw
    project_ref = str(secrets.get("PROJECT_REF", "")).strip()
    host_name = host_path.split("/", 1)[0].rsplit(":", 1)[0]
    if (
        "." not in username
        and project_ref
        and host_name.endswith(".pooler.supabase.com")
    ):
        # Supavisor uses the project ref in the PostgreSQL username as the
        # tenant identifier when connecting through the Session pooler.
        username = f"{username}.{project_ref}"
    return (
        f"{scheme}://{quote(username, safe='')}:{quote(password, safe='')}"
        f"@{host_path}"
    )

def run_command(cmd: list, env_vars: dict = None) -> bool:
    env = os.environ.copy()
    if env_vars:
        env.update(env_vars)
    log(f"Executing: {' '.join(cmd)}")
    result = subprocess.run(cmd, env=env)
    return result.returncode == 0

def require_supabase_secret(secrets: dict) -> tuple[str, str]:
    project_ref = str(secrets.get("PROJECT_REF", "")).strip()
    database_password = str(secrets.get("DATABASE_PASSWORD", "")).strip()
    if not database_password:
        for uri_key in (
            "SUPABASE_CONNECT_URI",
            "DATABASE_SESSION_POOLER_URL",
            "DATABASE_POOLER_URL",
            "DATABASE_DIRECT_URL",
        ):
            uri = str(secrets.get(uri_key, "")).strip()
            if uri:
                database_password = unquote(urlsplit(uri).password or "")
                if database_password:
                    break
    if not project_ref or not database_password:
        raise SystemExit(
            "Vault Supabase secret must contain PROJECT_REF and a password in "
            "DATABASE_PASSWORD or SUPABASE_CONNECT_URI"
        )
    if not str(
        secrets.get(
            "SUPABASE_CONNECT_URI",
            secrets.get(
                "DATABASE_SESSION_POOLER_URL",
                secrets.get("DATABASE_POOLER_URL", secrets.get("DATABASE_DIRECT_URL", "")),
            ),
        )
    ).strip():
        raise SystemExit(
            "Vault Supabase secret must contain SUPABASE_CONNECT_URI or "
            "DATABASE_SESSION_POOLER_URL"
        )
    return project_ref, database_password


def require_runtime_secret(secrets: dict, key: str) -> str:
    value = str(secrets.get(key, "")).strip()
    if not value:
        raise SystemExit(f"Vault runtime secret must contain {key}")
    return value


def optional_runtime_secrets(secrets: dict, keys: dict[str, str], label: str) -> dict:
    """Return an optional runtime secret group when it is configured.

    Optional capabilities must be configured atomically. An absent group is
    valid and is omitted from the service environment; a partially configured
    group is rejected so the service cannot start with an unusable contract.
    """
    values = {
        runtime_key: str(secrets.get(vault_key, "")).strip()
        for runtime_key, vault_key in keys.items()
    }
    configured = [value for value in values.values() if value]
    if not configured:
        log(f"Optional {label} runtime secrets are not configured; skipping.")
        return {}
    if len(configured) != len(values):
        missing = [runtime_key for runtime_key, value in values.items() if not value]
        raise SystemExit(
            f"Vault {label} runtime secret group is incomplete; missing {', '.join(missing)}"
        )
    return values


def deploy_cloudflare(script_dir: str, env_context: dict) -> None:
    if not DEPLOY_CLOUDFLARE:
        log("Cloudflare deployment is disabled.")
        return

    target_scripts = {
        "ssr": "deploy_portal_opennext_worker.sh",
        "edge-worker": "deploy_portal_opennext_worker.sh",
        "page-worker": "deploy_portal_opennext_worker.sh",
        "dashboard": "deploy_cloudflare_pages.sh",
        "pages": "deploy_cloudflare_pages.sh",
        "static-pages": "deploy_cloudflare_pages.sh",
        "edge-gateway": "deploy_cloudflare_worker.sh",
    }
    if not CLOUDFLARE_TARGET:
        raise SystemExit("CLOUDFLARE_TARGET is required for direct Cloudflare deployment")
    if CLOUDFLARE_TARGET not in target_scripts:
        raise SystemExit(f"Unsupported Cloudflare target: {CLOUDFLARE_TARGET}")
    script_names = [target_scripts[CLOUDFLARE_TARGET]]

    for script_name in script_names:
        script = os.path.join(script_dir, script_name)
        if not os.path.exists(script):
            raise SystemExit(f"Required portal deployment script is missing: {script}")
        target_context = dict(env_context)
        target_context["CLOUDFLARE_TARGET"] = CLOUDFLARE_TARGET
        if not run_command([script], target_context):
            raise SystemExit(f"Portal Cloudflare deployment failed: {script_name}")

def main():
    log(f"Starting serverless orchestration deployment for environment {VAULT_ENV_PATH}...")

    if not any((DEPLOY_CLOUDFLARE, DEPLOY_CLOUD_RUN, VERIFY_SUPABASE)):
        raise SystemExit("Select at least one component: Cloudflare, Cloud Run, or Supabase")

    cf_secrets = fetch_vault_secret("cloudflare") if DEPLOY_CLOUDFLARE else {}
    gcp_secrets = fetch_vault_secret("gcp") if DEPLOY_CLOUD_RUN else {}
    supabase_secrets = fetch_vault_secret("supabase") if (DEPLOY_CLOUD_RUN or VERIFY_SUPABASE) else {}
    runtime_secrets = fetch_vault_path("kv/data/WEB_SAAS") if DEPLOY_CLOUD_RUN else {}
    cicd_secrets = fetch_vault_path("kv/data/CICD") if DEPLOY_CLOUD_RUN else {}
    billing_secrets = fetch_vault_path(
        f"kv/data/{VAULT_ENV_PATH}/billing-service"
    ) if DEPLOY_CLOUD_RUN else {}
    deploys_accounts = DEPLOY_CLOUD_RUN and (
        not CLOUD_RUN_SERVICE or CLOUD_RUN_SERVICE == "accounts"
    )
    xconnect_zero_secrets = fetch_vault_path(
        f"kv/data/{VAULT_ENV_PATH}/xconnect-one"
    ) if deploys_accounts else {}
    github_oauth_runtime = {}
    if deploys_accounts:
        github_oauth_runtime = resolve_github_oauth_runtime()

    if DEPLOY_CLOUD_RUN or VERIFY_SUPABASE:
        require_supabase_secret(supabase_secrets)
        log("Supabase connection contract validated from Vault.")

    database_uri = normalize_runtime_database_uri(supabase_secrets)
    if DEPLOY_CLOUD_RUN and not database_uri:
        raise SystemExit("Vault Supabase secret must provide SUPABASE_CONNECT_URI")
    internal_service_token = (
        require_runtime_secret(runtime_secrets, "INTERNAL_SERVICE_TOKEN")
        if DEPLOY_CLOUD_RUN
        else ""
    )
    knowledge_repo_path = (
        require_runtime_secret(runtime_secrets, "KNOWLEDGE_REPO_PATH")
        if DEPLOY_CLOUD_RUN
        else ""
    )
    root_bootstrap_password = (
        require_runtime_secret(cicd_secrets, "ROOT_BOOTSTRAP_PASSWORD")
        if DEPLOY_CLOUD_RUN
        else ""
    )
    auth_token_secrets = {
        key: require_runtime_secret(runtime_secrets, key)
        for key in (
            "AUTH_TOKEN_PUBLIC_TOKEN",
            "AUTH_TOKEN_REFRESH_SECRET",
            "AUTH_TOKEN_ACCESS_SECRET",
        )
    } if DEPLOY_CLOUD_RUN else {}
    xconnect_zero_runtime = (
        optional_runtime_secrets(
            xconnect_zero_secrets,
            {
                "XCONNECT_OVERLAY_SIGNING_PRIVATE_KEY": "ZERO_SIGNING_PRIVATE_KEY",
                "XCONNECT_OVERLAY_SIGNING_KEY_ID": "ZERO_SIGNING_KEY_ID",
            },
            "XConnect Zero Signing",
        )
        if deploys_accounts
        else {}
    )
    shared_tenant_domain = (
        str(runtime_secrets.get("XWORKMATE_SHARED_TENANT_DOMAIN", "onwalk.net")).strip()
        if DEPLOY_CLOUD_RUN
        else ""
    )
    bridge_server_url = (
        str(
            runtime_secrets.get(
                "XWORKMATE_BRIDGE_SERVER_URL",
                f"https://bridge-{VAULT_ENV_PATH}.onwalk.net",
            )
        ).strip()
        if DEPLOY_CLOUD_RUN
        else ""
    )
    env_context = {
        "CLOUDFLARE_ACCOUNT_ID": cf_secrets.get("CLOUDFLARE_ACCOUNT_ID", os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")),
        "CLOUDFLARE_API_TOKEN": cf_secrets.get("CLOUDFLARE_API_TOKEN", os.environ.get("CLOUDFLARE_API_TOKEN", "")),
        "GCP_PROJECT_ID": gcp_secrets.get("GCP_PROJECT_ID", os.environ.get("GCP_PROJECT_ID", "")),
        "GCP_REGION": gcp_secrets.get("GCP_REGION", os.environ.get("GCP_REGION", "asia-east1")),
        "SUPABASE_CONNECT_URI": database_uri,
        "INTERNAL_SERVICE_TOKEN": internal_service_token,
        "KNOWLEDGE_REPO_PATH": knowledge_repo_path,
        "KNOWLEDGE_REPO_URL": runtime_secrets.get(
            "KNOWLEDGE_REPO_URL", "https://github.com/ai-workspace-services/knowledge.git"
        ),
        "KNOWLEDGE_REPO_REF": runtime_secrets.get("KNOWLEDGE_REPO_REF", "main"),
        "ROOT_BOOTSTRAP_EMAIL": cicd_secrets.get(
            "ROOT_BOOTSTRAP_EMAIL", "admin@svc.plus"
        ),
        "ROOT_BOOTSTRAP_PASSWORD": root_bootstrap_password,
        **auth_token_secrets,
        **xconnect_zero_runtime,
        "XWORKMATE_SHARED_TENANT_DOMAIN": shared_tenant_domain,
        "XWORKMATE_SHARED_TENANT_DOMAINS": runtime_secrets.get(
            "XWORKMATE_SHARED_TENANT_DOMAINS", shared_tenant_domain
        ),
        "XWORKMATE_BRIDGE_SERVER_URL": bridge_server_url,
        **github_oauth_runtime,
        "JWT_SECRET": os.environ.get("JWT_SECRET", "uat-jwt-secret-default"),
        "CONFIG_TEMPLATE": "/app/config/account.cloudrun.yaml",
        "SMTP_HOST": runtime_secrets.get("SMTP_HOST", "smtp.gmail.com"),
        "SMTP_PORT": runtime_secrets.get("SMTP_PORT", "587"),
        "SMTP_FROM": runtime_secrets.get(
            "SMTP_FROM", "XWorkmate <no-reply@xworktech.com>"
        ),
        "STRIPE_SECRET_KEY": billing_secret(billing_secrets, "STRIPE_SECRET_KEY"),
        "STRIPE_WEBHOOK_SECRET": billing_secret(billing_secrets, "STRIPE_WEBHOOK_SECRET"),
        "STRIPE_XCONNECT_PAY_URL": billing_secret(billing_secrets, "STRIPE_XCONNECT_PAY_URL"),
    }

    script_dir = os.path.dirname(os.path.abspath(__file__))

    # Deploy selected GCP Cloud Run microservices.
    cloudrun_script = os.path.join(script_dir, "deploy_cloudrun_services.sh")
    if DEPLOY_CLOUD_RUN and os.path.exists(cloudrun_script):
        cloudrun_context = dict(env_context)
        # Pass the workflow-selected immutable tag explicitly.  The child shell
        # script must never fall back to a historical snapshot tag from a
        # runner/environment default.
        cloudrun_context["IMAGE_TAG"] = os.environ.get("IMAGE_TAG", "latest").strip() or "latest"
        cloudrun_context["GCP_ARTIFACT_REGISTRY_REGION"] = os.environ.get(
            "GCP_ARTIFACT_REGISTRY_REGION", cloudrun_context["GCP_REGION"]
        )
        cloudrun_context["DEPLOY_ENV"] = VAULT_ENV_PATH
        cloudrun_context["CLOUD_RUN_SERVICE"] = CLOUD_RUN_SERVICE
        console_origins = resolve_console_origins(CLOUDFLARE_BOUNDARY_CONFIG)
        if CLOUDFLARE_BOUNDARY_CONFIG and not console_origins:
            raise SystemExit(
                "CLOUDFLARE_BOUNDARY_CONFIG is set but no console origin could be "
                "resolved from spec.serverless.console_host; refusing to deploy "
                "accounts without its CORS allowlist"
            )
        if not console_origins:
            log(
                "Warning: CLOUDFLARE_BOUNDARY_CONFIG is not set, so ALLOWED_ORIGINS "
                "cannot be derived. accounts will fall back to the origins baked "
                "into its config template, which may reject this environment's "
                "browser logins with an empty 403."
            )
        else:
            log(f"Cloud Run CORS origins: {', '.join(console_origins)}")
        cloudrun_context["ALLOWED_ORIGINS"] = ",".join(console_origins)
        if not run_command([cloudrun_script], cloudrun_context):
            log("Error: Cloud Run deployment failed")
            sys.exit(1)

    # Deploy selected Cloudflare Pages and portal OpenNext Worker targets.
    deploy_cloudflare(script_dir, env_context)

    log("✅ [Success] Selected Serverless components deployed successfully.")

if __name__ == "__main__":
    main()
