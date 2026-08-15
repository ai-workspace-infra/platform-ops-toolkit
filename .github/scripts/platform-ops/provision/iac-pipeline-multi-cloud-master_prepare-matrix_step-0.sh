#!/bin/bash
A="${INPUT_ACCOUNTS_COMPONENTS_____VPC_ROLE_}"
[ "$A" == "all" ] && A="vpc,role"
echo "account=$(echo "$A" | tr -d ' ' | jq -R -c 'split(",")')" >> "$GITHUB_OUTPUT"

R="${INPUT_RESOURCES_COMPONENTS_____S3_EC2_}"
[ "$R" == "all" ] && R="s3,ec2"
echo "resources=$(echo "$R" | tr -d ' ' | jq -R -c 'split(",")')" >> "$GITHUB_OUTPUT"
