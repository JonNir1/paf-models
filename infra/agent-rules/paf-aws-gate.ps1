# paf-aws-gate.ps1: shared PreToolUse hook for Claude Code and Antigravity (Gemini).
# Install at ~/.agents/hooks/paf-aws-gate.ps1 (replaces both block-aws-cli.ps1 copies).
#
#   raw aws CLI: any position, quoted, full path, or as a     -> deny
#     process argument (system2("aws", ..), ["aws", ..])
#   AWS SDKs (boto3, botocore, paws, aws.s3, AWS.Tools)        -> deny
#   reads of ~/.aws, SSO cache, credential export, AWS_*      -> deny
#     credential/profile variables, --profile paf-agent
#   R/cloud code or paf_aws.R run directly (not via the shim) -> ask / force_ask
#   paf-aws.ps1 launch | terminate | promote                  -> ask (Claude) / force_ask (Antigravity)
#   paf-aws.ps1 read-only subcommand, alone on one line       -> allow
#   paf-aws.ps1 in a compound or multi-line command / unknown -> ask / force_ask
#   paf-aws.ps1 whose files changed since pinned              -> deny (only if a pin file exists)
#   gate error on a command that mentions aws                 -> deny (fail closed)
#   anything else                                             -> no decision (Claude) / allow (Antigravity, as before)
#
# Limit: a hook sees only the command line. Code an agent writes to a file and then runs is
# invisible here; the PafAgent IAM policy and the Batch caps are the hard boundary for that.
#
# Optional pin: ~/.agents/hooks/paf-aws.sha256 holds the hash printed by
#   powershell -NoProfile -File ~/.agents/hooks/paf-aws-gate.ps1 -PrintPin <repo root>
# Re-pin after you review a change to scripts/paf-aws.ps1, R/cloud/, R/utils.R or R/helpers/logging.R.

param([string]$PrintPin = "")

$ReadOnly = @("whoami", "plan", "status", "logs", "cost", "sync")
$Mutating = @("launch", "terminate", "promote")
$PinFile = Join-Path $HOME ".agents\hooks\paf-aws.sha256"

function Get-WrapperHash([string]$root) {
    $files = @()
    foreach ($rel in @("scripts\paf-aws.ps1", "R\utils.R", "R\helpers\logging.R")) {
        $files += @(Get-Item -LiteralPath (Join-Path $root $rel) -ErrorAction SilentlyContinue)
    }
    $cloud = Join-Path $root "R\cloud"
    if (Test-Path -LiteralPath $cloud) {
        $files += Get-ChildItem -LiteralPath $cloud -Recurse -File -Filter *.R | Sort-Object FullName
    }
    if ($files.Count -eq 0) { return "" }
    $joined = ($files | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        $rel + ":" + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }) -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "")
}

if ($PrintPin) { Get-WrapperHash ((Resolve-Path $PrintPin).Path); exit 0 }

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
$isAgy = $raw -match '"toolCall"'

function Out-Decision([string]$decision, [string]$reason) {
    if ($isAgy) {
        if ($decision -eq "ask") { $decision = "force_ask" }
        @{ decision = $decision; reason = $reason } | ConvertTo-Json -Compress
        exit 0
    }
    if ($decision -eq "none") { exit 0 }
    @{ hookSpecificOutput = @{
        hookEventName = "PreToolUse"; permissionDecision = $decision; permissionDecisionReason = $reason } } |
        ConvertTo-Json -Compress -Depth 5
    exit 0
}

function Exit-NoDecision { if ($isAgy) { Out-Decision "allow" "" } else { exit 0 } }

function Invoke-Gate {
$json = $raw | ConvertFrom-Json
if ($isAgy) {
    $cmd = $json.toolCall.args.CommandLine
    if ([string]::IsNullOrEmpty($cmd)) { $cmd = $json.toolCall.args.command }
} else {
    $cmd = $json.tool_input.command
}
$cwd = $json.cwd

if ([string]::IsNullOrEmpty($cmd)) { Exit-NoDecision }

$rawAws = '(?i)(^|[\s;&|(){}\[\],''"`=\\/])aws(\.exe|\.cmd)?[''"]?(\s+\S|\s*[,)\]])'
if ($cmd -match $rawAws) {
    Out-Decision "deny" ("Raw aws CLI is off-limits for agents. Use scripts/paf-aws.ps1 (status/plan/logs/cost/sync are allowed; " +
        "launch/terminate/promote need the user's approval), or give the user the exact command to run themselves.")
}
$sdk = '(?i)(\bboto3\b|\bbotocore\b|\bpaws(\.[a-z]+)?\b|\baws\.(s3|ec2|signature)\b|AWS\.Tools|AWSPowerShell)'
if ($cmd -match $sdk) {
    Out-Decision "deny" "AWS SDK use is off-limits for agents; AWS access goes only through scripts/paf-aws.ps1."
}
$credRead = ('(?i)(\.aws[\\/]|[\\/]\.aws\b|sso[\\/]cache|export-credentials|AWS_SHARED_CREDENTIALS_FILE|AWS_CONFIG_FILE|' +
    'AWS_(PROFILE|DEFAULT_PROFILE|ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)|\$env:AWS_|printenv\s+AWS_|--profile\s+[''"]?paf-agent)')
if ($cmd -match $credRead) {
    Out-Decision "deny" "Agents never read AWS credential or config files, SSO caches or AWS credential/profile variables."
}

$runsR = '(?i)\b(Rscript|Rterm)(\.exe)?\b|\bR(\.exe)?[ \t]+(-e|-f|--file|--vanilla|--no-save|--slave)\b'
if ($cmd -match $runsR -and $cmd -match '(?i)(R[\\/]cloud|paf_aws)') {
    Out-Decision "ask" "Runs the cloud wrapper's R code directly instead of scripts/paf-aws.ps1: approve only if you expect it."
}

if ($cmd -notmatch '(?i)paf-aws(\.ps1)?') { Exit-NoDecision }

if ((Test-Path -LiteralPath $PinFile) -and $cwd) {
    $root = (& git -C $cwd rev-parse --show-toplevel 2>$null)
    if ($root) {
        $root = (Resolve-Path $root).Path
        $pinned = (Get-Content -LiteralPath $PinFile -Raw).Trim()
        if ((Get-WrapperHash $root) -ne $pinned) {
            Out-Decision "deny" "scripts/paf-aws.ps1 or R/cloud/ changed since the user pinned them. The user must review the change and re-pin."
        }
    }
}

# One line only: a newline separates commands in every shell, and \s would match it.
$launcher = '((powershell|pwsh)(\.exe)?[ \t]+(-(NoProfile|NonInteractive|ExecutionPolicy[ \t]+Bypass)[ \t]+)*-File[ \t]+)?'
$single = '^[ \t]*(&[ \t]*)?' + $launcher + '[''"]?(\.[\\/])?scripts[\\/]paf-aws\.ps1[''"]?(?<args>([ \t]+[A-Za-z0-9._:/=,+-]+)*)[ \t]*$'
if ($cmd -match '[\r\n]' -or $cmd -notmatch $single) {
    Out-Decision "ask" "paf-aws.ps1 inside a compound, multi-line or unusual command line: approve only if every part is expected."
}
$sub = (($Matches["args"].Trim() -split '[ \t]+') | Select-Object -First 1).ToLower()

if ($Mutating -contains $sub) {
    Out-Decision "ask" "PAF cloud action '$sub': approve only if it matches the plan you approved in chat (plan id, jobs, cost)."
}
if ($ReadOnly -contains $sub) { Out-Decision "allow" "Read-only paf-aws subcommand." }
Out-Decision "ask" "Unknown paf-aws subcommand '$sub'."
}

try {
    $ErrorActionPreference = "Stop"
    Invoke-Gate
} catch {
    if ($raw -match '(?i)aws|boto|paws') {
        Out-Decision "deny" ("paf-aws-gate failed on a command that mentions AWS, so it is blocked: " + $_.Exception.Message)
    }
    Exit-NoDecision
}
