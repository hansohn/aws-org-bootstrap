# aws-account-bootstrap

Day-0 CloudFormation seed for a **hubless** multi-account Terraform/Terragrunt
setup. One small template lays down everything a fresh AWS account needs to be
deployed into directly from GitHub Actions — no central CI account, no role
chaining.

## The hubless model

GitHub Actions authenticates to **each account directly** via OIDC and assumes
that account's own deploy role. There is no shared "deployer" account in the
path.

```
GitHub Actions (OIDC token, scoped by repo/branch)
        │
        ▼  AssumeRoleWithWebIdentity   (one hop)
  CodeDeployRole  ──►  terraform/terragrunt apply  ──►  tfstate in this account's S3
   (this account)                                        (native S3 lockfile)
```

Every target account gets its **own** OIDC provider + deploy role, seeded by
this template. That replication is normally the annoying part of hubless — the
StackSet makes it zero-toil.

## What the seed creates (per account)

| Resource | Purpose | Cost |
|---|---|---|
| `AWS::IAM::OIDCProvider` | Trust GitHub's token issuer | free |
| `AWS::IAM::Role` (`Org/CodeDeployRole`) | What GitHub assumes directly; `sub`-scoped trust | free |
| `AWS::S3::Bucket` | Terraform backend, versioned + encrypted, **native lock** (no DynamoDB) | ~cents |
| `AWS::S3::BucketPolicy` | Deny non-TLS access | free |
| `AWS::SSM::Parameter` ×2–3 | Self-register state bucket / role ARN / alias | free |
| `AWS::Budgets::Budget` | Monthly cost guard w/ email alerts | free (first 2) |

Deliberately **not** here (opt-in later): AWS Config, GuardDuty, Security Hub,
centralized logging, Transit Gateway. See the cost discussion in the design
notes — those are where real spend starts.

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
cp params/account-seed.example.json params/account-seed.json
```

The one parameter you must get right is **`GitHubSubjectClaims`** — the OIDC
`sub` patterns allowed to assume the role. This is your security boundary:

```
repo:hansohn/terragrunt-aws-template:ref:refs/heads/main   # only main
repo:hansohn/terragrunt-aws-template:*                     # any ref (looser)
repo:hansohn/terragrunt-aws-template:environment:prod      # a GH environment
```

### Option 1 — one account (self-managed)

Run with credentials for the target account (e.g. assume its
`OrganizationAccountAccessRole` from the management account):

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

After the seed applies, the stack output `DeployRoleArn` is the ARN your
workflow assumes. Store it per environment (GitHub → Settings → Environments →
`sandbox`/`prod` → secrets) so each environment maps to its own account:

```yaml
permissions:
  id-token: write        # REQUIRED for OIDC
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
      aws-region: us-west-2
```

## Integration with the Terragrunt template

Because deploys are **direct**, the runner is already authenticated *in* the
target account — so Terragrunt no longer needs to look the account up:

- **Account ID** comes from `aws sts get-caller-identity` (you're already in the
  account), replacing the `organizations:list-accounts` lookup entirely — no
  org-wide enumeration, nothing to leak.
- **State bucket / role ARN** can be read from the SSM parameters this seed
  writes (`/org/tf/state-bucket`, `/org/tf/deploy-role-arn`) instead of being
  reconstructed by string convention.

## Local plans (least privilege)

CI applies as `CodeDeployRole` (OIDC only). Humans get a separate **read-only
`CodePlanRole`** so local plans match CI without granting apply rights. Set
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
role_arn = arn:aws:iam::111122223333:role/Org/CodePlanRole
source_profile = sandbox-sso
```

```bash
aws sso login --profile sandbox-sso
AWS_PROFILE=sandbox-plan terragrunt plan
```

## Parameters

See `templates/account-seed.yaml` for the full list. The ones you'll usually
set: `GitHubSubjectClaims`, `PlanRoleTrustedPrincipalArns`,
`BudgetNotificationEmail`, `BudgetLimitUSD`, and `CreateOIDCProvider=false` if
the account already has a GitHub OIDC provider (only one is allowed per account).

## Notes

- The state bucket is `DeletionPolicy: Retain` — deleting the stack never
  deletes your Terraform state.
- The deploy role defaults to `AdministratorAccess`. That's typical for a
  bootstrap deployer, but scope `DeployRoleManagedPolicyArns` down once your
  footprint is known.

<!-- MARKDOWN LINKS & IMAGES -->
[image]: https://github.com/hansohn/cloudformation-docker
