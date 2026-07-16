#!/usr/bin/env bash
#
# Deploy the org-level baseline (org CloudTrail) ONCE to the management account.
# Run with management-account credentials.
#
# One-time prerequisite (no CloudFormation resource exists for it):
#   aws organizations enable-aws-service-access \
#     --service-principal cloudtrail.amazonaws.com
#
#   AWS_REGION=us-west-2 ./scripts/deploy-org.sh params/org-baseline.json
#
set -euo pipefail

STACK_NAME="${ORG_STACK_NAME:-org-baseline}"
REGION="${AWS_REGION:-us-west-2}"
TEMPLATE="templates/org-baseline.yaml"
PARAMS_FILE="${1:-params/org-baseline.json}"

if [[ ! -f "$PARAMS_FILE" ]]; then
  echo "error: params file not found: $PARAMS_FILE" >&2
  echo "       copy params/org-baseline.example.json and edit it." >&2
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
