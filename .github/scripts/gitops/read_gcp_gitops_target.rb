#!/usr/bin/env ruby

require "yaml"

manifest_path = ENV.fetch("GCP_GITOPS_MANIFEST")
manifest = YAML.safe_load(File.read(manifest_path), permitted_classes: [], permitted_symbols: [], aliases: false)
global = manifest.fetch("global")
project_id = global.fetch("project_id").to_s
region = global.fetch("region").to_s

abort("GitOps GCP project_id is empty") if project_id.empty?
abort("GitOps GCP region is empty") if region.empty?

{ "project_id" => project_id, "region" => region }.each do |key, value|
  output = ENV["GITHUB_OUTPUT"]
  File.open(output, "a") { |io| io.puts "#{key}=#{value}" } if output
end

puts "GitOps GCP target loaded: project=#{project_id}, region=#{region}"
