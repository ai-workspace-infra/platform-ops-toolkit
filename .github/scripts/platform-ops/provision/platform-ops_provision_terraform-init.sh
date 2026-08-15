#!/bin/bash
terraform init -input=false \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${ENV_STEPS_ROUTE_OUTPUTS_STATE_KEY}"
