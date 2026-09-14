#!/usr/bin/env python3
"""Validate the non-sensitive PersonalAIAggregator GitOps contract."""

from __future__ import annotations

import ipaddress
import sys
from pathlib import Path

import yaml


def fail(message: str) -> None:
    raise SystemExit(f"manifest validation failed: {message}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate_ai_aggregator_manifest.py <manifest>")
    path = Path(sys.argv[1])
    data = yaml.safe_load(path.read_text())
    if data.get("kind") != "PersonalAIAggregator":
        fail("kind must be PersonalAIAggregator")
    
    meta = data.get("metadata", {})
    env = meta.get("environment")
    spec = data.get("spec", {})
    entrypoint = spec.get("entrypoint", {})
    
    if entrypoint.get("component") != "caddy":
        fail("Caddy must be the public entrypoint")
    
    # Environment to domain binding check:
    domain = entrypoint.get("domain", "")
    if env == "uat":
        if domain != "ai.onwalk.net":
            fail(f"UAT environment must bind to *.onwalk.net (got: {domain})")
        if entrypoint.get("direct_api_domain") != "direct.ai.onwalk.net":
            fail("UAT direct_api_domain must be direct.ai.onwalk.net")
    elif env == "prod":
        if domain != "ai.svc.plus":
            fail(f"PROD environment must bind to ai.svc.plus (got: {domain})")
        if entrypoint.get("direct_api_domain") != "direct.ai.svc.plus":
            fail("PROD direct_api_domain must be direct.ai.svc.plus")

    if not str(entrypoint.get("admin_basic_auth_ref", "")).startswith("vault://"):
        fail("Caddy admin Basic Auth material must be referenced from Vault")

    infrastructure = spec.get("infrastructure", {})
    contract = infrastructure.get("resource_contract", {})
    if env == "uat":
        if infrastructure.get("provider") != "aws" or infrastructure.get("provisioner") != "terraform":
            fail("UAT infrastructure must use the AWS Terraform adapter")
        if infrastructure.get("lifecycle") != "ephemeral" or not infrastructure.get("spot_instance"):
            fail("UAT infrastructure must be ephemeral Spot resources")
        if infrastructure.get("max_runtime_minutes") != 60:
            fail("UAT infrastructure max_runtime_minutes must be 60")
        if infrastructure.get("destroy_policy") != "always_after_pipeline":
            fail("UAT infrastructure must always be destroyed after the pipeline")
    elif env == "prod":
        if infrastructure.get("provider") != "existing" or infrastructure.get("provisioner") != "ansible":
            fail("PROD infrastructure must use existing nodes and Ansible")
        if infrastructure.get("lifecycle") != "persistent" or infrastructure.get("terraform_manage_lifecycle"):
            fail("PROD infrastructure must remain persistent and outside Terraform lifecycle management")
        if infrastructure.get("destroy_policy") != "never":
            fail("PROD infrastructure destroy policy must be never")
    if not contract.get("repository") or not contract.get("path") or contract.get("ref") != "main":
        fail("infrastructure.resource_contract must pin repository, path, and ref")

    if spec.get("new_api", {}).get("bind_address") not in {"127.0.0.1", "::1"}:
        fail("New API must bind to loopback")

    litellm = spec.get("litellm", {})
    if litellm.get("bind_address") not in {"127.0.0.1", "::1"}:
        fail("LiteLLM must bind to loopback")
    if not isinstance(litellm.get("port"), int) or litellm["port"] == spec["new_api"].get("port"):
        fail("LiteLLM must declare a distinct integer port")
    if litellm.get("persistence", {}).get("driver") != "postgresql":
        fail("LiteLLM persistence must use PostgreSQL")
    if not str(litellm.get("persistence", {}).get("secret_ref", "")).startswith("vault://"):
        fail("LiteLLM PostgreSQL DSN must be referenced from Vault")
    if not str(litellm.get("master_key_ref", "")).startswith("vault://"):
        fail("LiteLLM master key must be referenced from Vault")
    provider_refs = litellm.get("provider_secret_refs", {})
    if set(provider_refs) != {"openai", "anthropic", "xai"} or not all(
        str(value).startswith("vault://") for value in provider_refs.values()
    ):
        fail("v1 LiteLLM must declare Vault references for OpenAI, Anthropic, and xAI")

    client_profiles = {profile.get("id"): profile for profile in spec.get("client_profiles", [])}
    expected_clients = {"claude-code", "android-studio", "openai-compatible"}
    if set(client_profiles) != expected_clients:
        fail("client_profiles must cover Claude Code, Android Studio, and OpenAI-compatible clients")
    for client_id, profile in client_profiles.items():
        if not profile.get("base_url", "").startswith("https://"):
            fail(f"client profile {client_id} must use HTTPS")
        if not profile.get("model_alias"):
            fail(f"client profile {client_id} must declare a model alias")
        if not str(profile.get("token_secret_ref", "")).startswith("vault://"):
            fail(f"client profile {client_id} must reference its token in Vault")
    if client_profiles["claude-code"].get("chain") != "new-api-cpa":
        fail("Claude Code must use the New API -> CPA chain")
    if client_profiles["android-studio"].get("chain") != "litellm-direct":
        fail("Android Studio must use the OpenAI-compatible LiteLLM direct chain")

    # Testing environment constraints for UAT: AWS Spot t4g 1h rule
    test_env = spec.get("testing_environment")
    if test_env:
        if test_env.get("provider") != "aws":
            fail("testing environment provider must be aws")
        if test_env.get("architecture") != "arm64":
            fail("testing environment architecture must be arm64")
        if not test_env.get("spot_instance"):
            fail("testing environment must use spot instances (spot_instance: true)")
        if test_env.get("max_runtime_minutes") != 60:
            fail("testing environment max_runtime_minutes must be 60")

    node_records = spec.get("nodes", [])
    nodes = {node["id"] for node in node_records}
    if spec.get("new_api", {}).get("node") not in nodes:
        fail("New API node is not declared")
    if any(not node.get("resource_ref") for node in node_records):
        fail("every infrastructure node must declare a resource_ref")

    instances = spec.get("cpa_instances", [])
    ids = [entry.get("id") for entry in instances]
    ports = [entry.get("port") for entry in instances]
    expected_ids = {"cpa-codex-01", "cpa-codex-02", "cpa-claude-01", "cpa-grok-01"}
    if set(ids) != expected_ids or len(ids) != len(set(ids)) or len(ports) != len(set(ports)):
        fail("CPA instance IDs and ports must be unique and non-empty")
    for instance in instances:
        if instance.get("node") not in nodes:
            fail(f"CPA instance {instance.get('id')} refers to an unknown node")
        if instance.get("bind_address") not in {"127.0.0.1", "::1"}:
            fail(f"CPA instance {instance.get('id')} must bind to loopback")
        if not str(instance.get("auth_secret_ref", "")).startswith("vault://"):
            fail(f"CPA instance {instance.get('id')} lacks a Vault reference")
        if not str(instance.get("channel_token_ref", "")).startswith("vault://"):
            fail(f"CPA instance {instance.get('id')} lacks a channel token Vault reference")
        if not str(instance.get("network_endpoint", "")).startswith("cmdb://"):
            fail(f"CPA instance {instance.get('id')} must use a CMDB private endpoint")
        if "@" not in str(instance.get("account_email", "")):
            fail(f"CPA instance {instance.get('id')} must declare account_email metadata")

    if env == "uat":
        for node in node_records:
            if node.get("provider") != "aws" or node.get("lifecycle") != "ephemeral":
                fail("UAT aggregator nodes must be AWS ephemeral resources")
            if not node.get("spot_instance") or node.get("max_runtime_minutes") != 60:
                fail("UAT aggregator nodes must use 60-minute Spot lifecycle")
    elif env == "prod":
        for node in node_records:
            if node.get("lifecycle") != "persistent" or node.get("provider") != "existing":
                fail("PROD aggregator nodes must be existing persistent nodes")

    enabled = bool(spec.get("enabled"))
    cidrs = entrypoint.get("source_cidrs", [])
    if enabled and cidrs:
        for cidr in cidrs:
            network = ipaddress.ip_network(cidr, strict=False)
            if network.prefixlen not in {32, 128}:
                fail("v1 only accepts fixed /32 or /128 source addresses")
    # enabled is a non-secret GitOps declaration. An empty allowlist keeps the
    # service intentionally unreachable while artifacts and Vault material are
    # being prepared; stage/activate enforce the allowlist separately.
    if enabled and cidrs:
        for name in ("new_api", "cliproxyapi"):
            artifact = spec.get("artifacts", {}).get(name, {})
            if not artifact.get("revision"):
                fail(f"enabled deployment requires {name} revision")
            if len(str(artifact.get("sha256", ""))) != 64:
                fail(f"enabled deployment requires {name} sha256")
            try:
                int(artifact["sha256"], 16)
            except ValueError:
                fail(f"{name} sha256 is not hexadecimal")
        if not spec.get("new_api", {}).get("start_command"):
            fail("enabled deployment requires a verified New API loopback start command")

    print(f"valid PersonalAIAggregator manifest: {path}")


if __name__ == "__main__":
    main()
