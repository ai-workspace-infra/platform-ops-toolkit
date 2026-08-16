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
DEPLOY_CLOUD_RUN = os.environ.get("DEPLOY_CLOUD_RUN", "true").lower() == "true"
VERIFY_SUPABASE = os.environ.get("VERIFY_SUPABASE", "true").lower() == "true"
CLOUD_RUN_SERVICE = os.environ.get("CLOUD_RUN_SERVICE", "").strip()
CLOUDFLARE_TARGET = os.environ.get("CLOUDFLARE_TARGET", "").strip()

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


def deploy_cloudflare(script_dir: str, env_context: dict) -> None:
    if not DEPLOY_CLOUDFLARE:
        log("Cloudflare deployment is disabled.")
        return

    target_scripts = {
        "edge-worker": "deploy_portal_opennext_worker.sh",
        "page-worker": "deploy_portal_opennext_worker.sh",
        "dashboard": "deploy_cloudflare_pages.sh",
        "pages": "deploy_cloudflare_pages.sh",
        "edge-gateway": "deploy_cloudflare_worker.sh",
    }
    if CLOUDFLARE_TARGET and CLOUDFLARE_TARGET not in target_scripts:
        raise SystemExit(f"Unsupported Cloudflare target: {CLOUDFLARE_TARGET}")
    script_names = [target_scripts[CLOUDFLARE_TARGET]] if CLOUDFLARE_TARGET else [
        "deploy_portal_opennext_worker.sh",
        "deploy_cloudflare_pages.sh",
    ]

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
        "JWT_SECRET": os.environ.get("JWT_SECRET", "uat-jwt-secret-default"),
        "CONFIG_TEMPLATE": "/app/config/account.cloudrun.yaml",
        "SMTP_HOST": runtime_secrets.get("SMTP_HOST", "smtp.qq.com"),
        "SMTP_PORT": runtime_secrets.get("SMTP_PORT", "587"),
        "SMTP_FROM": runtime_secrets.get(
            "SMTP_FROM", "XControl Account <no-reply@example.com>"
        ),
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
        if not run_command([cloudrun_script], cloudrun_context):
            log("Error: Cloud Run deployment failed")
            sys.exit(1)

    # Deploy selected Cloudflare Pages and portal OpenNext Worker targets.
    deploy_cloudflare(script_dir, env_context)

    log("✅ [Success] Selected Serverless components deployed successfully.")

if __name__ == "__main__":
    main()
