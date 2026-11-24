# AWS Cookbook

End-to-end recipe for running a fit / recovery / PPC job on a throwaway EC2 instance and
syncing results through S3. Three phases: **launch** (PowerShell, local), **run** (bash,
on the instance), **terminate** (PowerShell, local).

> **Bucket:** PAF files live under the `paf-models/` prefix of the `jon-nir` bucket, so set
> `BUCKET=jon-nir/paf-models`. The scripts use `s3://$BUCKET/...` as the path root.
>
> **Never run `aws-cli` against these resources from an agent session** (blocked by a hook).
> These commands are for a human to run in their own terminal.

---

## 1. Launch instance (PowerShell, local)

Resolve the security group and write the spot-options file (inline JSON is mangled by
PowerShell quoting, so it must go through a file):

```powershell
$SG_ID = aws ec2 describe-security-groups --filters "Name=group-name,Values=paf-sg" `
           --query "SecurityGroups[0].GroupId" --output text

'{"MarketType":"spot"}' | Out-File -Encoding ascii "$env:TEMP\spot-options.json"
```

Pick an instance type and name:

```powershell
$INSTANCE_TYPE = "c5.large"      # c5.xlarge (smoke) / c6a.4xlarge (recovery, production)
$INSTANCE_NAME = "paf-instance"  # informative, e.g. "paf-ppc-mymodel"
```

> **Optional: pin a subnet** (recommended, avoids capacity issues). List them with
> `aws ec2 describe-subnets --query "Subnets[*].[SubnetId,AvailabilityZone]" --output table`,
> then add `--subnet-id $SUBNET_ID` to the launch call below.

Launch, wait for it to come up, and grab its public IP:

```powershell
$ID = aws ec2 run-instances `
  --image-id ami-00403f401ee6a4b98 `
  --instance-type $INSTANCE_TYPE `
  --key-name paf-key `
  --security-group-ids $SG_ID `
  --iam-instance-profile Name=paf-ec2-profile `
  --associate-public-ip-address `
  --instance-market-options "file://$env:TEMP\spot-options.json" `
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" `
  --query "Instances[0].InstanceId" --output text

aws ec2 wait instance-running --instance-ids $ID

$IP = aws ec2 describe-instances --instance-ids $ID `
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text

ssh -i "$HOME\Documents\projects\__secrets__\paf-key.pem" ubuntu@$IP
```

---

## 2. Run the job (bash, on the EC2 instance)

```bash
BUCKET=jon-nir/paf-models
```

### Machine setup (one-time per VM)

```bash
REPO_URL=https://github.com/JonNir1/paf-models.git

sudo git clone "$REPO_URL" /opt/paf-models
sudo chown -R "$USER":"$USER" /opt/paf-models
cd /opt/paf-models

./scripts/vm_setup.sh   # installs R + EMC2, ~5 minutes
```

### Kick off a run

Each script downloads its own inputs from S3 and syncs outputs back automatically; no manual
`aws s3 cp` is needed before or after.

| Script | Example args | Purpose |
|---|---|---|
| `run_fit.sh` | `--model-script R/fit/mymodel.R` | build fresh + fit to convergence |
| `run_fit.sh` | `--resume 260618_mymodel.rds` | resume a saved fit |
| `run_recovery.sh` | `260618_mymodel.rds 1` | single-sim parameter recovery |
| `run_recovery.sh` | `260618_mymodel.rds 1 --fit-model-script R/fit/other.R` | model recovery: refit the simulated data with another model |
| `run_ppc.sh` | `260618_mymodel.rds` | posterior predictive simulation |
| `run_bf.sh` | `260618_mymodel.rds` | bridge-sampling marginal likelihood (Bayes factors; synced to `results/bf/`) |

```bash
nohup env BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/<script> <args> > ~/run.log 2>&1 &
echo "PID: $!"
```

### Monitor

```bash
tail -f ~/run.log
```

### Optional: manual sync of leftover outputs

The script hooks sync model `.rds` files automatically. Use this only for extra outputs the
hook does not cover:

```bash
# RESULTS_SUB_DIR=ppc   # ppc / recovery / fit / bf
# aws s3 sync outputs/models/fit_ppc/ "s3://jon-nir/paf-models/results/$RESULTS_SUB_DIR/"
```

---

## 3. Terminate + verify (PowerShell, local)

```powershell
aws ec2 terminate-instances --instance-ids $ID
aws ec2 wait instance-terminated --instance-ids $ID
aws ec2 describe-instances --instance-ids $ID `
  --query "Reservations[0].Instances[0].State.Name" --output text   # -> "terminated"
```
