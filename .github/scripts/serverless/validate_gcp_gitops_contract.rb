#!/usr/bin/env ruby

require "yaml"

manifest_path = ENV.fetch("GCP_GITOPS_MANIFEST")
environment = ENV.fetch("GCP_ENVIRONMENT")
vault_project_id = ENV.fetch("GCP_PROJECT_ID")
vault_region = ENV.fetch("GCP_REGION")

manifest = YAML.safe_load(File.read(manifest_path), permitted_classes: [], permitted_symbols: [], aliases: false)
global = manifest.is_a?(Hash) ? manifest["global"] : nil
abort("GCP GitOps manifest must contain a global mapping") unless global.is_a?(Hash)

expected_environment = global.fetch("environment", "").to_s
expected_project_id = global.fetch("project_id", "").to_s
expected_region = global.fetch("region", "").to_s
artifact_registry_location = global.fetch("artifact_registry_location", "").to_s

abort("GCP manifest environment mismatch: expected #{environment}, found #{expected_environment}") unless expected_environment == environment
abort("Resolved GCP_PROJECT_ID does not match GitOps: expected #{expected_project_id}, found #{vault_project_id}") unless vault_project_id == expected_project_id
abort("Resolved GCP_REGION does not match GitOps: expected #{expected_region}, found #{vault_region}") unless vault_region == expected_region
abort("GitOps Artifact Registry location must match the declared GCP region") unless artifact_registry_location == expected_region

puts "GCP Vault/GitOps contract verified: environment=#{environment}, project=#{expected_project_id}, region=#{expected_region}"
