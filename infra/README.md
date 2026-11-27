# PAF cloud infrastructure (AWS Batch, agent-safe)

Agents (Claude Code, Gemini) run PAF jobs on AWS Batch through `scripts/paf-aws.ps1` only, with the
short-lived SSO role `PafAgent`. Everything in this directory is applied **by the human admin**, from
**AWS CloudShell** (bash, us-east-1), so no admin credentials ever sit on the PC. Agents never run these
commands. No account IDs, ARNs or URLs are committed: they are resolved at apply time.

| File | What |
|---|---|
| `cloudformation/paf-guardrails.yaml` | CloudTrail trail (own bucket), monthly budget + email alerts, budget kill switch (disables the paf queues/CEs, terminates their jobs at 100%) |
| `cloudformation/paf-batch.yaml` | Spot CE (max 64 vCPU) + on-demand CE (max 16), queues `paf-spot`/`paf-ondemand`, job definition `paf-job`, job role (S3 prefix only), egress-only SG, IMDSv2 hop 1, logs 30 d, reaper Lambda |
| `iam/paf-agent-permission-set.json` | Inline policy of the `PafAgent` permission set |
| `iam/paf-ec2-role-s3.json` | Replacement S3 policy for the legacy `paf-ec2-role` (prefix only) |
| `agent-rules/` | Proposed hook script and rule text for the agents (applied by you to your global config) |

## Apply order

Prerequisites: the code is pushed to `origin` and the image is built (`gh workflow run image.yml`);
note the pushed digest (in the run's summary). After the FIRST push only, make the package public so
Batch can pull it without registry credentials: GitHub -> your profile -> Packages -> `paf-r` ->
Package settings -> Change visibility -> Public (it holds only R, EMC2 and the bootstrap script; no
code, data or secrets). In CloudShell: `git clone https://github.com/JonNir1/paf-models.git && cd paf-models`
and check out the branch that holds `infra/`.

```bash
REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
for t in infra/cloudformation/*.yaml; do aws cloudformation validate-template --template-body "file://$t" >/dev/null && echo "OK $t"; done
```

### 1. Identity: Organizations + IAM Identity Center

Console: Organizations -> Create organization (all features); IAM Identity Center -> Enable (region
us-east-1); Settings -> Authentication -> MFA "Every time they sign in", authenticator apps/security keys;
Settings -> Session duration 12 h. Users -> add yourself (one user). Then:

```bash
INSTANCE_ARN=$(aws sso-admin list-instances --query 'Instances[0].InstanceArn' --output text)
STORE_ID=$(aws sso-admin list-instances --query 'Instances[0].IdentityStoreId' --output text)
USER_ID=$(aws identitystore list-users --identity-store-id "$STORE_ID" \
  --filters AttributePath=UserName,AttributeValue=<your-sso-username> --query 'Users[0].UserId' --output text)

# Agent permission set: 1 h role sessions, inline policy only.
PS_AGENT=$(aws sso-admin create-permission-set --instance-arn "$INSTANCE_ARN" --name PafAgent \
  --session-duration PT1H --description "PAF agent: submit and monitor paf Batch jobs only" \
  --query PermissionSet.PermissionSetArn --output text)
aws sso-admin put-inline-policy-to-permission-set --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$PS_AGENT" --inline-policy file://infra/iam/paf-agent-permission-set.json

# Your own admin permission set (replaces paf-cli for console / CloudShell work).
PS_ADMIN=$(aws sso-admin create-permission-set --instance-arn "$INSTANCE_ARN" --name PafAdmin \
  --session-duration PT1H --query PermissionSet.PermissionSetArn --output text)
aws sso-admin attach-managed-policy-to-permission-set --instance-arn "$INSTANCE_ARN" \
  --permission-set-arn "$PS_ADMIN" --managed-policy-arn arn:aws:iam::aws:policy/AdministratorAccess

for PS in "$PS_AGENT" "$PS_ADMIN"; do
  aws sso-admin create-account-assignment --instance-arn "$INSTANCE_ARN" --target-id "$ACCOUNT_ID" \
    --target-type AWS_ACCOUNT --permission-set-arn "$PS" --principal-type USER --principal-id "$USER_ID"
done
```

After a policy edit: `put-inline-policy-to-permission-set` again, then
`aws sso-admin provision-permission-set --instance-arn "$INSTANCE_ARN" --permission-set-arn "$PS_AGENT" --target-type ALL_PROVISIONED_ACCOUNTS`.

### 2. Guardrails stack

```bash
aws cloudformation deploy --stack-name paf-guardrails \
  --template-file infra/cloudformation/paf-guardrails.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides AlertEmail=<your-email> MonthlyBudgetUsd=50 --tags Project=paf
```

Confirm the SNS subscription email. Raising the budget for a heavy step (other parameters keep their
values): `aws cloudformation deploy --stack-name paf-guardrails --template-file infra/cloudformation/paf-guardrails.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides MonthlyBudgetUsd=<new>`.

### 3. Batch stack

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/batch/job --query 'logGroups[].logGroupName'   # must be empty (the stack creates it)
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=map-public-ip-on-launch,Values=true \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
aws cloudformation deploy --stack-name paf-batch \
  --template-file infra/cloudformation/paf-batch.yaml --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides VpcId="$VPC_ID" SubnetIds="$SUBNETS" \
    ImageUri=ghcr.io/jonnir1/paf-r@sha256:<digest> --tags Project=paf
aws batch describe-compute-environments --compute-environments paf-spot-ce paf-ondemand-ce \
  --query 'computeEnvironments[].[computeEnvironmentName,status,state]' --output table   # VALID ENABLED
```

A new image: rerun the deploy with the new `ImageUri` (registers a new `paf-job` revision).

### 4. Narrow the legacy instance role

```bash
aws iam put-role-policy --role-name paf-ec2-role --policy-name paf-s3-prefix \
  --policy-document file://infra/iam/paf-ec2-role-s3.json
aws iam detach-role-policy --role-name paf-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
```

### 5. This PC: SSO profile for the agents

Append to `%USERPROFILE%\.aws\config` (the start URL is on the Identity Center dashboard):

```ini
[sso-session paf]
sso_start_url = <your access portal URL>
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile paf-agent]
sso_session = paf
sso_account_id = <account id>
sso_role_name = PafAgent
region = us-east-1
output = json
```

Once a day you run `aws sso login --profile paf-agent` (browser + MFA); the CLI then refreshes the 1 h
role credentials by itself for the 12 h portal session. Agents never run it.

## Verification

In CloudShell (admin):

```bash
ROLE_ARN=$(aws iam list-roles --path-prefix /aws-reserved/sso.amazonaws.com/ \
  --query "Roles[?starts_with(RoleName,'AWSReservedSSO_PafAgent_')].Arn" --output text)
sim() { aws iam simulate-principal-policy --policy-source-arn "$ROLE_ARN" "$@" \
  --query 'EvaluationResults[].[EvalActionName,EvalResourceName,EvalDecision]' --output table; }

# Expect explicitDeny for all:
sim --action-names ec2:RunInstances iam:CreateUser iam:PassRole batch:UpdateComputeEnvironment \
  batch:RegisterJobDefinition cloudtrail:StopLogging budgets:ModifyBudget lambda:InvokeFunction s3:DeleteObject
# Expect allowed, implicitDeny, implicitDeny:
sim --action-names s3:GetObject --resource-arns arn:aws:s3:::jon-nir/paf-models/inputs/data/exp1/Exp1_clean.csv \
  arn:aws:s3:::jon-nir/other/file arn:aws:s3:::paf-cloudtrail-$ACCOUNT_ID/AWSLogs/x
# Expect allowed (inputs/fit), implicitDeny (results is written by jobs only):
sim --action-names s3:PutObject --resource-arns arn:aws:s3:::jon-nir/paf-models/inputs/fit/x.rds \
  arn:aws:s3:::jon-nir/paf-models/results/fit/x.rds
# SubmitJob: allowed with the required tags, implicitDeny without.
Q=arn:aws:batch:$REGION:$ACCOUNT_ID:job-queue/paf-spot
sim --action-names batch:SubmitJob --resource-arns "$Q" --context-entries \
  ContextKeyName=aws:RequestTag/Project,ContextKeyValues=paf,ContextKeyType=string \
  ContextKeyName=aws:RequestTag/Owner,ContextKeyValues=agent,ContextKeyType=string \
  ContextKeyName=aws:TagKeys,ContextKeyValues=Project,Owner,ContextKeyType=stringList
sim --action-names batch:SubmitJob --resource-arns "$Q"

aws lambda invoke --function-name paf-reaper /tmp/reaper.json && cat /tmp/reaper.json   # {"jobs": [], "instances": []}
```

On this PC (PowerShell, after `aws sso login --profile paf-agent`):

```powershell
aws ec2 run-instances --dry-run --image-id ami-00403f401ee6a4b98 --instance-type c5.xlarge --profile paf-agent   # UnauthorizedOperation
aws s3 ls s3://jon-nir/paf-models/inputs/ --profile paf-agent      # lists
aws s3 ls s3://jon-nir/ --profile paf-agent                         # AccessDenied
```

Kill-switch drill (optional, disables the queues): `aws lambda invoke --function-name paf-budget-kill /tmp/kill.json`,
then re-enable:

```bash
for ce in paf-spot-ce paf-ondemand-ce; do aws batch update-compute-environment --compute-environment $ce --state ENABLED; done
for q in paf-spot paf-ondemand; do aws batch update-job-queue --job-queue $q --state ENABLED; done
```

## Retire the legacy path (after a successful smoke run)

```bash
aws ec2 describe-security-groups --group-names paf-sg --query 'SecurityGroups[0].IpPermissions'
aws ec2 revoke-security-group-ingress --group-name paf-sg --protocol tcp --port 22 --cidr 0.0.0.0/0   # match the rule shown above
aws iam list-access-keys --user-name paf-cli
aws iam update-access-key --user-name paf-cli --access-key-id <id> --status Inactive   # delete-access-key once nothing breaks
```

Then remove the paf-cli entry from your local `~/.aws/credentials` yourself.
