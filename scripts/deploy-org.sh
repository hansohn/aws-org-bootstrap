#!/usr/bin/env bash
#
# Deploy the organization CloudTrail ONCE to the management account.
# Run with management-account credentials.
#
# One-time prerequisite (no CloudFormation resource exists for it):
#   aws organizations enable-aws-service-access \
#     --service-principal cloudtrail.amazonaws.com
#
#   AWS_REGION=us-west-2 ./scripts/deploy-org.sh params/cloudtrail.json
#
set -euo pipefail

STACK_NAME="${ORG_STACK_NAME:-org-cloudtrail}"
REGION="${AWS_REGION:-us-west-2}"
TEMPLATE="templates/cloudtrail.yaml"
PARAMS_FILE="${1:-params/cloudtrail.json}"

if [[ ! -f "$PARAMS_FILE" ]]; then
  echo "error: params file not found: $PARAMS_FILE" >&2
  echo "       copy params/cloudtrail.example.json and edit it." >&2
  exit 1
fi

# aws cloudformation deploy wants Key=Value overrides, not a params file.
mapfile -t OVERRIDES < <(jq -r '.[] | "\(.ParameterKey)=\(.ParameterValue)"' "$PARAMS_FILE")

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --parameter-overrides "${OVERRIDES[@]}" \
  --region "$REGION" \
  --no-fail-on-empty-changeset

echo
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs' \
  --output table
