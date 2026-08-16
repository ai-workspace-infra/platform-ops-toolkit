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
from urllib.parse import urlsplit, unquote

VAULT_ADDR = os.environ.get("VAULT_ADDR", "https://vault.svc.plus").rstrip("/")
VAULT_TOKEN = os.environ.get("VAULT_TOKEN", "")
VAULT_ENV_PATH = os.environ.get("VAULT_ENV_PATH", os.environ.get("DEPLOY_ENV", "uat")).strip()
if VAULT_ENV_PATH not in {"dev", "sit", "uat", "prod"}:
    raise SystemExit("VAULT_ENV_PATH/DEPLOY_ENV must be one of: dev, sit, uat, prod")
SERVERLESS_BASE_PATH = os.environ.get(
    "VAULT_SERVERLESS_PATH", f"kv/data/{VAULT_ENV_PATH}/serverless"
).strip().rstrip("/")

def log(msg: str):
    print(f"==> [UAT Orchestrator] {msg}", flush=True)

def fetch_vault_secret(subpath: str) -> dict:
    if not VAULT_TOKEN:
        log(f"Warning: VAULT_TOKEN not set, skipping Vault fetch for {subpath}")
        return {}
    url = f"{VAULT_ADDR}/v1/{SERVERLESS_BASE_PATH}/{subpath}"
    req = urllib.request.Request(url, headers={"X-Vault-Token": VAULT_TOKEN})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("data", {}).get("data", {}) or data.get("data", {})
    except Exception as e:
        log(f"Failed to fetch Vault secret at {url}: {e}")
        return {}

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
        direct_uri = str(secrets.get("DATABASE_DIRECT_URL", "")).strip()
        database_password = unquote(urlsplit(direct_uri).password or "")
    if not project_ref or not database_password:
        raise SystemExit(
            "Vault Supabase secret must contain PROJECT_REF and DATABASE_PASSWORD "
            "or DATABASE_DIRECT_URL"
        )
    return project_ref, database_password

def main():
    log(f"Starting serverless orchestration deployment for environment {VAULT_ENV_PATH}...")

    # 1. 从 Vault 获取凭据
    cf_secrets = fetch_vault_secret("cloudflare")
    gcp_secrets = fetch_vault_secret("gcp")
    supabase_secrets = fetch_vault_secret("supabase")
    app_secrets = fetch_vault_secret("app-secrets")
    supabase_project_ref, supabase_database_password = require_supabase_secret(supabase_secrets)

    env_context = {
        "CLOUDFLARE_ACCOUNT_ID": cf_secrets.get("CLOUDFLARE_ACCOUNT_ID", os.environ.get("CLOUDFLARE_ACCOUNT_ID", "")),
        "CLOUDFLARE_API_TOKEN": cf_secrets.get("CLOUDFLARE_API_TOKEN", os.environ.get("CLOUDFLARE_API_TOKEN", "")),
        "GCP_PROJECT_ID": gcp_secrets.get("GCP_PROJECT_ID", os.environ.get("GCP_PROJECT_ID", "")),
        "GCP_REGION": gcp_secrets.get("GCP_REGION", os.environ.get("GCP_REGION", "asia-east1")),
        "SUPABASE_PROJECT_REF": supabase_project_ref,
        "SUPABASE_DATABASE_PASSWORD": supabase_database_password,
        "DATABASE_URL": supabase_secrets.get(
            "DATABASE_SESSION_POOLER_URL",
            supabase_secrets.get("DATABASE_POOLER_URL", os.environ.get("DATABASE_URL", "")),
        ),
        "JWT_SECRET": app_secrets.get("JWT_SECRET", os.environ.get("JWT_SECRET", "uat-jwt-secret-default")),
    }

    script_dir = os.path.dirname(os.path.abspath(__file__))

    # 2. 部署 GCP Cloud Run 微服务
    cloudrun_script = os.path.join(script_dir, "deploy_cloudrun_services.sh")
    if os.path.exists(cloudrun_script):
        if not run_command([cloudrun_script], env_context):
            log("Error: Cloud Run deployment failed")
            sys.exit(1)

    # 3. 部署 Cloudflare Worker 网关
    cf_worker_script = os.path.join(script_dir, "deploy_cloudflare_worker.sh")
    if os.path.exists(cf_worker_script):
        if not run_command([cf_worker_script], env_context):
            log("Error: Cloudflare Worker deployment failed")
            sys.exit(1)

    # 4. 部署 Cloudflare Pages 前端控制台
    cf_pages_script = os.path.join(script_dir, "deploy_cloudflare_pages.sh")
    if os.path.exists(cf_pages_script):
        if not run_command([cf_pages_script], env_context):
            log("Error: Cloudflare Pages deployment failed")
            sys.exit(1)

    log("✅ [Success] All UAT Serverless components deployed successfully.")

if __name__ == "__main__":
    main()
