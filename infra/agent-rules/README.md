# Agent rules for the PAF cloud wrapper (you apply these)

Rules live in one file, `~/.agents/AGENTS.md`, which both `~/.claude/CLAUDE.md` and `~/.gemini/GEMINI.md`
import. Hooks are harness config, not instructions, so each harness registers the same shared script,
`paf-aws-gate.ps1`. IAM (`infra/iam/paf-agent-permission-set.json`) is the hard boundary; the hook and
rules keep agents on the approved path and put a human prompt in front of every mutating action.

## 1. Install the shared hook

```powershell
New-Item -ItemType Directory -Force "$HOME\.agents\hooks" | Out-Null
Copy-Item infra\agent-rules\paf-aws-gate.ps1 "$HOME\.agents\hooks\paf-aws-gate.ps1"
```

Behavior (checked against 41 sample commands in both payload formats plus 2 malformed payloads; the
first version of this script failed 29 of those checks, see the commit log):

| Command | Claude | Antigravity |
|---|---|---|
| raw `aws ...`: any position, quoted, full path (`...\aws.exe`), `aws.cmd`, or as a process argument (`system2("aws", ..)`, `["aws", ..]`) | deny | deny |
| AWS SDKs on the command line (`boto3`, `botocore`, `paws`, `aws.s3`, `AWS.Tools`) | deny | deny |
| reads of `~/.aws`, SSO cache, `export-credentials`, `AWS_*` credential/profile variables, `--profile paf-agent` | deny | deny |
| `Rscript`/`R` running `R/cloud/` or `paf_aws.R` directly (bypassing the shim) | ask | force_ask |
| `scripts/paf-aws.ps1 whoami/plan/status/logs/cost/sync`, alone on one line | allow | allow |
| `scripts/paf-aws.ps1 launch/terminate/promote` | ask | force_ask |
| `paf-aws.ps1` in a compound or multi-line command, or an unknown subcommand | ask | force_ask |
| wrapper files changed since pinned (only with a pin file) | deny | deny |
| the gate itself errors on a payload that mentions AWS | deny (fail closed) | deny |
| anything else | no decision | allow (same as the current hook) |

What it cannot see: code an agent writes to a file and then runs (the hook reads only the command
line). The hard boundary for that is IAM: within `PafAgent`, an agent could at worst submit tagged paf
jobs, which the 64 vCPU cap, the job timeout, the reaper and the budget kill switch then bound.

Two things worth checking on your side: whether Antigravity treats a hook's `allow` as "skip the normal
approval prompt" (the current hook already answers `allow` for every unrelated command), and whether it
has other shell-running tools besides `run_command` (if so, add them to its matcher).

## 2. Register it

`~/.claude/settings.json`: in `hooks.PreToolUse`, replace the whole `block-aws-cli.ps1` entry with
this one. The matcher now also covers `Monitor` and the terminal-panel tool, which run shell commands
too (the current hook does not see them):

```json
{
  "matcher": "Bash|PowerShell|Monitor|mcp__terminal__run_in_terminal",
  "hooks": [
    {
      "type": "command",
      "command": "powershell -NoProfile -File \"C:\\Users\\nirjo\\.agents\\hooks\\paf-aws-gate.ps1\"",
      "timeout": 15
    }
  ]
}
```

Keep `permissions.deny` (`Bash(aws *)`, `PowerShell(aws *)`) as is.

`~/.gemini/config/hooks.json`: replace the `"block-aws-cli"` entry with

```json
"paf-aws-gate": {
  "PreToolUse": [
    {
      "matcher": "run_command",
      "hooks": [
        {
          "type": "command",
          "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\nirjo\\.agents\\hooks\\paf-aws-gate.ps1\"",
          "timeout": 10
        }
      ]
    }
  ]
}
```

Then delete the two old `block-aws-cli.ps1` copies (`~/.claude/hooks/`, `~/.gemini/config/hooks/`).

## 3. Pin the wrapper (optional hardening, recommended)

After you have reviewed the merged wrapper on `main`:

```powershell
powershell -NoProfile -File "$HOME\.agents\hooks\paf-aws-gate.ps1" -PrintPin C:\Users\nirjo\Documents\University\PhD\Projects\paf-models | Out-File -Encoding ascii "$HOME\.agents\hooks\paf-aws.sha256"
```

From then on, any change to `scripts/paf-aws.ps1`, `R/cloud/`, or the two files the wrapper sources
from outside it (`R/utils.R`, `R/helpers/logging.R`) makes the hook deny the wrapper until you review
and re-run the command above.

## 4. `~/.agents/AGENTS.md`

Replace the two bullets "Never run `aws-cli` against the user's AWS resources ..." and "Spinning up new EC2
instances is done manually by the user only ..." with:

```markdown
- Never run the raw `aws` CLI or AWS SDK calls (boto3, paws, etc.) yourself, in commands or in scripts. The only AWS access agents have is the paf-models wrapper `scripts/paf-aws.ps1` (SSO profile `paf-agent`), run from a paf-models checkout. For anything else on AWS, explain what is needed and give the user the exact command(s) to run themselves.
- With the wrapper, read-only subcommands (`whoami`, `plan`, `status`, `logs`, `cost`, `sync`) need no approval. `launch`, `terminate` and `promote` need the user's explicit approval in chat, per action, of the plan the wrapper printed (jobs, instance type, spot or on-demand, count, estimated cost and wall time, teardown rule). Spot is the default; propose on-demand only for long runs. Never raise caps, timeouts or budgets yourself.
- Never run `aws sso login` or handle AWS credentials, config files or SSO caches. If the wrapper reports an expired session, ask the user to log in.
- Agents never launch EC2 instances or create or change cloud infrastructure (IAM, roles, budgets, quotas, Batch environments, launch templates). Write the change (policy JSON, CloudFormation, commands) and let the user apply it. Cloud jobs run on AWS Batch through the wrapper only.
- Do not edit the wrapper (`scripts/paf-aws.ps1`, `R/cloud/`) and use it in the same task; a changed wrapper needs the user's review and re-pin first.
- While jobs run, check status at most every 20-30 minutes (the wrapper's status calls are free; `cost` calls Cost Explorer and costs money, so use it sparingly).
```
