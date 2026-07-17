<div align="center">
  <h3>aws-org-bootstrap</h3>
  <p>Day-0 CloudFormation for a multi-account AWS org</p>
  <p>
    <!-- Build Status -->
    <a href="https://github.com/hansohn/aws-org-bootstrap/actions/workflows/validate.yml">
      <img src="https://img.shields.io/github/actions/workflow/status/hansohn/aws-org-bootstrap/validate.yml?branch=main&style=for-the-badge">
    </a>
    <!-- GitHub Tag -->
    <a href="https://github.com/hansohn/aws-org-bootstrap/tags/">
      <img src="https://img.shields.io/github/tag/hansohn/aws-org-bootstrap.svg?style=for-the-badge">
    </a>
    <!-- License -->
    <a href="https://github.com/hansohn/aws-org-bootstrap/blob/main/LICENSE">
      <img src="https://img.shields.io/github/license/hansohn/aws-org-bootstrap.svg?style=for-the-badge">
    </a>
  </p>
</div>

Day-0 CloudFormation for a multi-account Terraform/Terragrunt setup, organized
in two layers:

- **`templates/hub-runner.yaml`** — the hub CI runner, deployed once to the
  management account: the org's only GitHub OIDC provider plus a near-powerless
  `TerraformRunnerRole` that resolves accounts via AWS Organizations and chains
  into each account's deploy role.
- **`templates/account-seed.yaml`** — per-account seed. Everything a fresh AWS
  account needs to be deployed into from GitHub Actions. Replicated across an
  OU by a StackSet.
- **`templates/cloudtrail.yaml`** — an org-level feature, deployed once to the
  management account (a multi-region organization CloudTrail). Each additional
  org-wide feature (GuardDuty, SCPs, …) gets its own top-level template here.

## The hub model

GitHub Actions authenticates **once** via OIDC into the management account's
`TerraformRunnerRole`, resolves the target account through AWS Organizations
(the org itself is the account registry — no committed account map, no per-repo
GitHub variables), then role-chains into that account's `TerraformDeploymentRole`:

```
GitHub Actions (OIDC token, scoped by repo/branch)
        │
        ▼  AssumeRoleWithWebIdentity   (hop 1)
  TerraformRunnerRole (management)
        │   organizations:ListAccounts  →  resolve deployment path → account id
        ▼  sts:AssumeRole              (hop 2, role chaining)
  TerraformDeploymentRole  ──►  terraform/terragrunt apply  ──►  tfstate in this account's S3
   (target account)                                               (native S3 lockfile)
```

The runner role can do exactly two things: list org accounts and assume roles
named `Org/TerraformDeploymentRole`. All GitHub↔AWS trust concentrates in its
`sub`-claim conditions — that one policy gates every account.

### The hubless alternative

The seed still supports direct trust: set `GitHubSubjectClaims` (and a
per-account OIDC provider) and GitHub assumes the account's deploy role in one
hop, no management-account involvement. Set both parameters to allow both
paths during a migration. Accounts that don't deploy from GitHub at all can opt
out entirely — see [Parameters](#parameters).

## What the seed creates (per account)

Both features below are on by default and opt-out per account (see
[Parameters](#parameters)): the GitHub deploy resources via
`EnableGitHubActionsDeploy`, the Terraform backend via `EnableTerraformBackend`.
The budget is always created.

| Resource | Purpose | Cost |
|---|---|---|
| `AWS::IAM::Role` (`Org/TerraformDeploymentRole`) | The deploy role — trusts the hub runner (and/or GitHub directly) | free |
| `AWS::IAM::OIDCProvider` | Trust GitHub's token issuer — **hubless accounts only** (the hub model needs no per-account provider) | free |
| `AWS::S3::Bucket` | Terraform backend, versioned + encrypted, **native lock** (no DynamoDB) | ~cents |
| `AWS::S3::BucketPolicy` | Deny non-TLS access | free |
| `AWS::SSM::Parameter` ×2–4 | Self-register state bucket / deploy-role ARN / account name + alias | free |
| `AWS::Budgets::Budget` | Monthly cost guard w/ email alerts | free (first 2) |

Deliberately **not** here (opt-in later): AWS Config, GuardDuty, Security Hub,
Transit Gateway. See the cost discussion in the design notes — those are where
real spend starts. (Organization CloudTrail *is* included, as
`cloudtrail.yaml` — management events are free; only S3 storage costs, pennies
at this scale.)

## Prerequisites

- An AWS Organization with the target accounts.
- For the **StackSet** path: run once from the management account —
  `aws cloudformation activate-organizations-access --region <region>`.
- The `aws` CLI, `jq`, and `cfn-lint` for local work — or skip installing them
  and use the bundled toolchain: `make dev` drops into a shell in the
  [`hansohn/cloudformation`][image] image (aws-cli, cfn-lint, rain, cfn-guard)
  with the repo and `~/.aws` mounted. CI lints in the same image.

## Deploy

Copy the example params and edit them (real files are gitignored):

```bash
cp params/hub-runner.example.json params/hub-runner.json
cp params/account-seed.example.json params/account-seed.json
```

The one parameter you must get right is **`GitHubSubjectClaims`** (on the hub
runner) — the OIDC `sub` patterns allowed to assume it. This is your security
boundary for the whole org:

```
repo:hansohn/terragrunt-aws-template:ref:refs/heads/main   # only main
repo:hansohn/terragrunt-aws-template:*                     # any ref (looser)
repo:hansohn/terragrunt-aws-template:environment:prod      # a GH environment
```

### Step 0 — the hub runner (once, management account)

```bash
AWS_REGION=us-west-2 make cfn/deploy-hub          # -> scripts/deploy-hub.sh
```

Take the `RunnerRoleArn` output and set it as `HubRunnerRoleArn` in
`params/account-seed.json`, then seed the accounts:

### Option 1 — one account (self-managed)

Run with credentials for the target account (e.g. assume its
`OrganizationAccountAccessRole` from the management account — this prompts for
MFA if the role's trust policy requires it):

```bash
AWS_REGION=us-west-2 make cfn/deploy             # -> scripts/deploy-account.sh
```

### Option 2 — a whole OU (service-managed, auto-deploy)

Run from the management account. New accounts that later join the OU are seeded
automatically:

```bash
OU_IDS=ou-abcd-11112222 AWS_REGION=us-west-2 make cfn/deploy-stackset
```

Same template, same params. Start with Option 1 and graduate to Option 2 — no
rework.

## Wiring it into GitHub Actions

Workflows reference exactly one constant — the hub runner's ARN. No per-repo
variables, no per-account secrets; the target account is resolved at runtime
from the deployment path:

```yaml
permissions:
  id-token: write        # REQUIRED for OIDC
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@v5   # hop 1: OIDC -> hub
    with:
      role-to-assume: arn:aws:iam::<MGMT_ACCOUNT_ID>:role/Org/TerraformRunnerRole
      aws-region: us-west-2

  - id: account          # resolve deployment path -> org account id
    run: |
      ACCOUNT_ID=$(aws organizations list-accounts \
        --query "Accounts[?Name=='${ACCOUNT_NAME}'].Id" --output text)
      echo "id=${ACCOUNT_ID}" >> "$GITHUB_OUTPUT"

  - uses: aws-actions/configure-aws-credentials@v5   # hop 2: hub -> target
    with:
      role-to-assume: arn:aws:iam::${{ steps.account.outputs.id }}:role/Org/TerraformDeploymentRole
      role-chaining: true
      aws-region: us-west-2
```

(Hubless accounts instead store the seed's `DeployRoleArn` output as a
repo/environment variable and assume it in one hop.)

## Integration with the Terragrunt template

By the time Terragrunt runs, the runner is already authenticated *in* the
target account — the org lookup happened in the workflow, not in Terragrunt:

- **Account ID** comes from `aws sts get-caller-identity` (you're already in
  the account).
- **State bucket / role ARN** can be read from the SSM parameters this seed
  writes (`/org/tf/state-bucket`, `/org/tf/deploy-role-arn`) instead of being
  reconstructed by string convention.
- **Deployment paths must match org account names** (`deployments/<name>/…` ↔
  the account's name in AWS Organizations) — that's the join key the workflow
  resolves with `organizations:ListAccounts`.

## Local plans (least privilege)

CI applies as `TerraformDeploymentRole` (via the hub, or direct OIDC). Humans get a separate
**read-only `TerraformPlanRole`** so local plans match CI without granting
apply rights. Set
`PlanRoleTrustedPrincipalArns` to your SSO permission-set role pattern to create
it (leave blank to skip — CI-only account):

```
arn:aws:iam::*:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_InfraDeveloper_*
```

It grants `ReadOnlyAccess` plus just enough S3 to read state and acquire the
native lock. Engineers chain into it via an AWS profile:

```ini
# ~/.aws/config
[profile sandbox-sso]
sso_session = corp
sso_account_id = 111122223333
sso_role_name = InfraDeveloper

[profile sandbox-plan]
role_arn = arn:aws:iam::111122223333:role/Org/TerraformPlanRole
source_profile = sandbox-sso
```

```bash
aws sso login --profile sandbox-sso
AWS_PROFILE=sandbox-plan terragrunt plan
```

## Parameters

See `templates/account-seed.yaml` for the full list. Two master switches let an
account opt out of a whole feature (both default `true`, overridable per account
via StackSet parameter overrides):

- `EnableGitHubActionsDeploy=false` — no OIDC provider, no deploy role. For an
  account that doesn't deploy from GitHub Actions at all (security, log-archive,
  centrally-managed).
- `EnableTerraformBackend=false` — no state bucket, no plan role. For an account
  that deploys from GitHub but not with Terraform.

The ones you'll usually set: `HubRunnerRoleArn` (hub model — the
`RunnerRoleArn` output of `hub-runner.yaml`), `PlanRoleTrustedPrincipalArns`,
`AccountName`/`AccountAlias`, `BudgetNotificationEmail`, and `BudgetLimitUSD`.
Hubless accounts instead set `GitHubSubjectClaims` (and
`CreateOIDCProvider=false` if the account already has a GitHub OIDC provider —
only one is allowed per account).

## Notes

- The state bucket is `DeletionPolicy: Retain` — deleting the stack never
  deletes your Terraform state.
- The deploy role defaults to `AdministratorAccess`. That's typical for a
  bootstrap deployer, but scope `DeployRoleManagedPolicyArns` down once your
  footprint is known.

<!-- MARKDOWN LINKS & IMAGES -->
[image]: https://github.com/hansohn/cloudformation-docker
