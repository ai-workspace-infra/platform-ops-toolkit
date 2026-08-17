#!/usr/bin/env bash
set -euo pipefail

INPUT_FILE="${GITOPS_ROUTING_YAML:?GITOPS_ROUTING_YAML must point to the GitOps YAML declaration}"
OUTPUT_FILE="${GITOPS_ROUTING_OUTPUT:?GITOPS_ROUTING_OUTPUT must point to a temporary JSON output file}"

test -f "${INPUT_FILE}" || {
  echo "GitOps routing declaration not found: ${INPUT_FILE}" >&2
  exit 1
}
command -v ruby >/dev/null 2>&1 || {
  echo "Ruby is required to render the GitOps YAML routing declaration" >&2
  exit 1
}

mkdir -p "$(dirname "${OUTPUT_FILE}")"
ruby -ryaml -rjson -e '
  input_file, output_file = ARGV
  document = YAML.safe_load(File.read(input_file), permitted_classes: [], permitted_symbols: [], aliases: false)
  abort("GitOps routing declaration must be a YAML mapping") unless document.is_a?(Hash)
  abort("GitOps routing declaration must be EdgeRoutingConfig") unless document["kind"] == "EdgeRoutingConfig"
  File.write(output_file, JSON.pretty_generate(document) + "\n")
' "${INPUT_FILE}" "${OUTPUT_FILE}"

echo "==> Rendered GitOps routing YAML: ${INPUT_FILE} -> ${OUTPUT_FILE}"
