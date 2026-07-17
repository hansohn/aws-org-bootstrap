#!/usr/bin/env bash
#
# Deploy the hub CI runner ONCE to the management account.
# Run with management-account credentials.
#
#   AWS_REGION=us-west-2 ./scripts/deploy-hub.sh params/hub-runner.json
#
# The stack output RunnerRoleArn is both the role workflows assume via OIDC
# and the HubRunnerRoleArn parameter for account-seed.yaml.
#
set -euo pipefail

STACK_NAME="${HUB_STACK_NAME:-tf-hub-runner}"
REGION="${AWS_REGION:-us-west-2}"
TEMPLATE="templates/hub-runner.yaml"
PARAMS_FILE="${1:-params/hub-runner.json}"

if [[ ! -f "$PARAMS_FILE" ]]; then
  echo "error: params file not found: $PARAMS_FILE" >&2
  echo "       copy params/hub-runner.example.json and edit it." >&2
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
