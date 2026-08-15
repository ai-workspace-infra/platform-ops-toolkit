#!/bin/bash
set -e

IFS=',' read -ra WF_LIST <<< "$WORKFLOWS"

for WF in "${WF_LIST[@]}"; do
  WF=$(echo "$WF" | xargs)
  echo "🔍 Checking workflow: $WF"

  RUN=$(gh api \
    "repos/$REPO/actions/workflows/$WF/runs" \
    -F branch="$BRANCH" \
    -F per_page=1 \
    --jq '.workflow_runs[0]')

  if [ "$RUN" = "null" ]; then
    echo "❌ No runs found for $WF"
    exit 1
  fi

  STATUS=$(echo "$RUN" | jq -r '.conclusion')

  if [ "$STATUS" != "success" ]; then
    echo "❌ $WF latest run is not successful: $STATUS"
    exit 1
  fi

  echo "✅ $WF is ready"
done
