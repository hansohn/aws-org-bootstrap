MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:
.SUFFIXES:

# include makefiles
export SELF ?= $(MAKE)
PROJECT_PATH ?= $(shell pwd)
include $(PROJECT_PATH)/Makefile.*

REPO_NAME ?= $(shell basename $(CURDIR))

#-------------------------------------------------------------------------------
# cloudformation
#-------------------------------------------------------------------------------

AWS_REGION     ?= us-west-2
TEMPLATE       ?= templates/account-seed.yaml
PARAMS         ?= params/account-seed.json
STACK_NAME     ?= tf-account-seed
STACKSET_NAME  ?= tf-account-seed
export AWS_REGION STACK_NAME STACKSET_NAME

## Check that the aws cli is available
cfn/check:
	@command -v aws > /dev/null 2>&1 || (echo "[ERROR] aws cli is not installed." && exit 1)
.PHONY: cfn/check

## Lint templates with cfn-lint
cfn/lint:
	@command -v cfn-lint > /dev/null 2>&1 || (echo "[ERROR] cfn-lint is not installed (pip install cfn-lint)." && exit 1)
	@echo "[INFO] Linting '$(TEMPLATE)'."
	@cfn-lint templates/*.yaml
.PHONY: cfn/lint

## Validate the template against the CloudFormation API
cfn/validate: cfn/check
	@echo "[INFO] Validating '$(TEMPLATE)'."
	@aws cloudformation validate-template --template-body file://$(TEMPLATE) --region $(AWS_REGION) > /dev/null && echo "[INFO] Template is valid."
.PHONY: cfn/validate

## Deploy the seed to a single account (self-managed)
cfn/deploy: cfn/check
	@echo "[INFO] Deploying '$(STACK_NAME)' to the current account."
	@./scripts/deploy-account.sh $(PARAMS)
.PHONY: cfn/deploy

## Deploy the seed to an OU (service-managed StackSet, set OU_IDS=...)
cfn/deploy-stackset: cfn/check
	@echo "[INFO] Deploying stack set '$(STACKSET_NAME)'."
	@./scripts/deploy-stackset.sh $(PARAMS)
.PHONY: cfn/deploy-stackset

## Delete the single-account stack (state bucket is retained)
cfn/delete: cfn/check
	@echo "[INFO] Deleting stack '$(STACK_NAME)'."
	@aws cloudformation delete-stack --stack-name $(STACK_NAME) --region $(AWS_REGION)
.PHONY: cfn/delete

#-------------------------------------------------------------------------------
# clean
#-------------------------------------------------------------------------------

## Clean local artifacts
clean:
	@echo "[INFO] Removing local build artifacts."
	@rm -f packaged.yaml
.PHONY: clean
