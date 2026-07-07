MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := dev
.DELETE_ON_ERROR:
.SUFFIXES:

# include makefiles
export SELF ?= $(MAKE)
PROJECT_PATH ?= $(shell pwd)
include $(PROJECT_PATH)/Makefile.*

export UNAME_S ?= $(shell uname -s)
REPO_NAME ?= $(shell basename $(CURDIR))

AWS_REGION     ?= us-west-2
TEMPLATE       ?= templates/account-seed.yaml
PARAMS         ?= params/account-seed.json
STACK_NAME     ?= tf-account-seed
STACKSET_NAME  ?= tf-account-seed
export AWS_REGION STACK_NAME STACKSET_NAME

#-------------------------------------------------------------------------------
# dev
#-------------------------------------------------------------------------------

DOCKER_IMAGE ?= hansohn/cloudformation
DOCKER_TAG   ?= latest
DOCKER_PULL  ?= always

DOCKER_ARGS ?=
DOCKER_ARGS += --interactive
DOCKER_ARGS += --tty
DOCKER_ARGS += --rm
DOCKER_ARGS += --env AWS_PROFILE --env AWS_REGION
DOCKER_ARGS += --workdir /app
DOCKER_ARGS += --volume $(PWD):/app
DOCKER_ARGS += --volume $(HOME)/.aws:/root/.aws
DOCKER_ARGS += --volume $(HOME)/.gitconfig:/root/.gitconfig:ro
DOCKER_ARGS += --pull $(DOCKER_PULL)

SSH_AUTH_SOCK_MAGIC_PATH := /run/host-services/ssh-auth.sock
ifeq ($(UNAME_S),Darwin)
DOCKER_ARGS += --env SSH_AUTH_SOCK=$(SSH_AUTH_SOCK_MAGIC_PATH)
DOCKER_ARGS += --volume $(SSH_AUTH_SOCK_MAGIC_PATH):$(SSH_AUTH_SOCK_MAGIC_PATH)
endif

## Run a local dev shell in the cloudformation image
dev: ENTRYPOINT ?= bash
dev:
	@docker run $(DOCKER_ARGS) $(DOCKER_IMAGE):$(DOCKER_TAG) $(ENTRYPOINT)
.PHONY: dev

#-------------------------------------------------------------------------------
# cloudformation
#-------------------------------------------------------------------------------

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
