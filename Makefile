SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

TEMPLATE      ?= templates/account-seed.yaml
PARAMS        ?= params/account-seed.json
AWS_REGION    ?= us-west-2
export AWS_REGION

## Show this help
help:
	@awk 'BEGIN{FS":.*##"} /^[a-zA-Z0-9_\/-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

## Lint the template (requires cfn-lint)
lint:
	cfn-lint $(TEMPLATE)

## Validate the template against the CloudFormation API
validate:
	aws cloudformation validate-template --template-body file://$(TEMPLATE) --region $(AWS_REGION) >/dev/null && echo "valid"

## Deploy the seed to a single account (self-managed)
deploy-account: ## uses $(PARAMS)
	./scripts/deploy-account.sh $(PARAMS)

## Register/update the service-managed StackSet (set OU_IDS=...)
deploy-stackset:
	./scripts/deploy-stackset.sh $(PARAMS)

.PHONY: help lint validate deploy-account deploy-stackset
