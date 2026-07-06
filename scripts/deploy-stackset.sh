#!/usr/bin/env bash
#
# Register/update the seed as a SERVICE-MANAGED StackSet and deploy it to
# one or more OUs, with auto-deployment to accounts that later join them.
# Run from the management account (or a delegated StackSets admin).
#
#   OU_IDS=ou-abcd-11112222,ou-abcd-33334444 \
#   AWS_REGION=us-west-2 \
#   ./scripts/deploy-stackset.sh params/account-seed.json
#
set -euo pipefail

STACKSET_NAME="${STACKSET_NAME:-tf-account-seed}"
REGION="${AWS_REGION:-us-west-2}"
TEMPLATE="templates/account-seed.yaml"
PARAMS_FILE="${1:-params/account-seed.json}"
: "${OU_IDS:?set OU_IDS to a comma-separated list of target OU ids}"

# Prerequisite (run once, from the management account):
#   aws cloudformation activate-organizations-access --region "$REGION"

if aws cloudformation describe-stack-set --stack-set-name "$STACKSET_NAME" \
     --region "$REGION" >/dev/null 2>&1; then
  echo "updating existing stack set: $STACKSET_NAME"
  aws cloudformation update-stack-set \
    --stack-set-name "$STACKSET_NAME" \
    --template-body "file://$TEMPLATE" \
    --parameters "file://$PARAMS_FILE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --permission-model SERVICE_MANAGED \
    --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
    --region "$REGION"
else
  echo "creating stack set: $STACKSET_NAME"
  aws cloudformation create-stack-set \
    --stack-set-name "$STACKSET_NAME" \
    --template-body "file://$TEMPLATE" \
    --parameters "file://$PARAMS_FILE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --permission-model SERVICE_MANAGED \
    --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
    --region "$REGION"

  echo "creating stack instances in OUs: $OU_IDS"
  aws cloudformation create-stack-instances \
    --stack-set-name "$STACKSET_NAME" \
    --deployment-targets "OrganizationalUnitIds=${OU_IDS}" \
    --regions "$REGION" \
    --operation-preferences FailureToleranceCount=0,MaxConcurrentPercentage=25 \
    --region "$REGION"
fi

echo "done. new accounts joining these OUs will be seeded automatically."
