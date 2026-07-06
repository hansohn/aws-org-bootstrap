#!/usr/bin/env bash
#
# Deploy the seed to a SINGLE account (self-managed / one-off).
# Run with credentials for the target account (e.g. assuming its
# OrganizationAccountAccessRole from the management account).
#
#   AWS_REGION=us-west-2 ./scripts/deploy-account.sh params/account-seed.json
#
set -euo pipefail

STACK_NAME="${STACK_NAME:-tf-account-seed}"
REGION="${AWS_REGION:-us-west-2}"
TEMPLATE="templates/account-seed.yaml"
PARAMS_FILE="${1:-params/account-seed.json}"

if [[ ! -f "$PARAMS_FILE" ]]; then
  echo "error: params file not found: $PARAMS_FILE" >&2
  echo "       copy params/account-seed.example.json and edit it." >&2
  exit 1
fi

# aws cloudformation deploy wants Key=Value overrides, not a params file.
mapfile -t OVERRIDES < <(jq -r '.[] | "\(.ParameterKey)=\(.ParameterValue)"' "$PARAMS_FILE")

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --parameter-overrides "${OVERRIDES[@]}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset

echo
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs' \
  --output table
