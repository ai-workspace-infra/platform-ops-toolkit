#!/usr/bin/env python3
"""Validate control-plane inputs before any execution-owner credentials."""
import json
import os
import re
import subprocess

MODES = {"preflight", "backup", "rehearsal", "upgrade", "rollback", "legacy_import", "akamai_preflight",
         "checkpoint", "probe", "baseline", "migrate", "selfhost_probe", "selfhost_init", "selfhost_verify",
         "core_users"}

IMPORT_FIELDS = {
    "confirm_legacy_import", "dry_run", "environment", "vault_env_path", "target_environment",
    "migration_scope", "toolkit_action", "caller_run_id", "accounts_transport",
    "accounts_source_backend", "accounts_target_backend", "accounts_migration_mode",
    "accounts_source_host", "accounts_target_host", "accounts_email_filter",
    "supabase_target_connection_mode", "supabase_target_existing_strategy",
    "supabase_target_confirm_replace", "supabase_metadata_dry_run", "supabase_project_ref",
    "supabase_vault_path", "supabase_source_vault_path", "supabase_target_dsn_key",
    "supabase_source_tunnel_host",
}


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def validate_config(config, mode=None):
    require(isinstance(config, dict), "config_json must be an object")
    if mode == 'legacy_import':
        require(set(config).issubset(IMPORT_FIELDS), 'unsupported import config field')
        require(all(isinstance(value, (str, bool, int)) for value in config.values()),
                'import config fields must be supported scalar values')
    def inspect(value):
        if isinstance(value, dict):
            for key, item in value.items():
                require(not re.search(r"(?i)(password|passphrase|private_?key|access_?token|bearer_?token|api_?key|secret_?key|credentials|command|script|sql|_dsn|_pass)$", key),
                        "credentials, SQL and commands are not workflow inputs")
                require(key not in {"dsn", "source_dsn", "target_dsn", "token", "secret"},
                        "credentials must be resolved by execution owners through Vault")
                inspect(item)
        elif isinstance(value, list):
            for item in value:
                inspect(item)
        elif isinstance(value, str):
            require(not re.search(r"(?i)(postgres(?:ql)?://|-----BEGIN .*PRIVATE KEY|\bbearer\s+\S+)", value),
                    "connection strings and private keys are prohibited")
    inspect(config)


def main():
    mode, environment = os.environ.get("OPERATION_MODE", ""), os.environ.get("DEPLOY_ENV", "")
    require(environment in {"uat", "prod"}, "explicit UAT or PROD environment required")
    require(mode in MODES, "unsupported data operation")
    require(mode != "rehearsal" or os.environ.get("GITHUB_RUN_ATTEMPT", "1") == "1",
            "rehearsal reruns are refused; investigate and dispatch a new complete run")
    config = json.loads(os.environ.get("DATA_CONFIG_JSON", "{}"))
    validate_config(config, mode)
    if 'execution_path' in config:
        if config['execution_path'] == 'selfhost_roles':
            require(environment == 'uat' and mode in {'preflight', 'backup'},
                    'Selfhost component roles are UAT-only preflight/backup, not full release acceptance')
        else:
            require(mode == 'core_users' and config['execution_path'] == 'selfhost_core_users',
                    'unknown execution_path')
    if 'account' in config:
        require(isinstance(config['account'], str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,62}", config['account']),
                "account must be a plain identifier")
    if mode in {"legacy_import", "akamai_preflight", "rehearsal", "baseline", "migrate", "selfhost_init"}:
        require(environment == "uat", f"{mode} is UAT-only")
    if mode == "legacy_import":
        require(config.get("confirm_legacy_import") is True, "one-time legacy import requires explicit confirm_legacy_import=true")
        require(config.get("supabase_target_existing_strategy", "reject") != "replace_public", "destructive replacement disabled")
        config.setdefault('dry_run', True)
        require(type(config['dry_run']) is bool, 'dry_run must be a JSON boolean')
    if mode == "core_users":
        require(environment == "prod", "core_users synchronization is PROD-only")
        require(re.fullmatch(r"v[0-9]+(?:\.[0-9]+)+(?:-r[1-9][0-9]*)?", os.environ.get("RELEASE_TAG", "")),
                "core_users requires an immutable PROD release tag")
        require(config.get("execution_path", "selfhost_core_users") == "selfhost_core_users",
                "core_users requires the fixed Selfhost execution path")
        require(config.get("source_read_only") is True,
                "core_users requires a Vault-resolved read-only source contract")
    if mode == "rollback":
        require(config.get("rollback_mode", "soft") == "soft", "automated database restore is disabled")
        require(False, "standalone same-digest rollback executor not registered; destructive DB restore retired")
    if mode == "akamai_preflight":
        require(isinstance(config.get("account"), str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,62}", config["account"]),
                "explicit Akamai account required")
    if environment == "prod":
        # Core-user synchronization is released only from an immutable tag.
        # The tag is the release approval boundary for this narrowly scoped,
        # read-only-source operation; it must not inherit an environment
        # reviewer requirement that would make the release rule unusable.
        if mode == "core_users":
            require(os.environ.get("GITHUB_REF") == f"refs/tags/{os.environ.get('RELEASE_TAG', '')}",
                    "core_users PROD runs must be dispatched from their immutable release tag")
        else:
            result = subprocess.run(["gh", "api", f"repos/{os.environ['GITHUB_REPOSITORY']}/environments/prod"],
                                    check=True, capture_output=True, text=True)
            protection = json.loads(result.stdout).get("protection_rules", [])
            require(any(rule.get("type") == "required_reviewers" and rule.get("reviewers")
                        and rule.get("prevent_self_review") is True for rule in protection),
                    "PROD requires configured reviewers and prevent_self_review=true")
    for field in ("expected_schema_version", "target_schema_version", "migration_sha256"):
        if os.environ.get(field.upper()):
            config[field] = os.environ[field.upper()]
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("config_json=" + json.dumps(config, separators=(",", ":")) + "\n")
            output.write("account=" + str(config.get("account", "")) + "\n")
    print(f"Validated {mode} request for {environment}; no credentials or resources changed")


if __name__ == "__main__":
    main()
