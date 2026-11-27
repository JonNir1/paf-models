# paf-aws-gate.ps1: shared PreToolUse hook for Claude Code and Antigravity (Gemini).
# Install at ~/.agents/hooks/paf-aws-gate.ps1 (replaces both block-aws-cli.ps1 copies).
#
#   raw aws CLI (any position, quoted or not)        -> deny
#   reads of ~/.aws, credential export, AWS_* env     -> deny
#   paf-aws.ps1 launch | terminate | promote          -> ask (Claude) / force_ask (Antigravity)
#   paf-aws.ps1 read-only subcommand, alone           -> allow
#   paf-aws.ps1 inside a compound command / unknown   -> ask / force_ask
#   paf-aws.ps1 whose files changed since pinned      -> deny (only if a pin file exists)
#   anything else                                     -> no decision (Claude) / allow (Antigravity, as before)
#
# Optional pin: ~/.agents/hooks/paf-aws.sha256 holds the hash printed by
#   powershell -NoProfile -File ~/.agents/hooks/paf-aws-gate.ps1 -PrintPin <repo root>
# Re-pin after you review a change to scripts/paf-aws.ps1 or R/cloud/.

param([string]$PrintPin = "")

$ReadOnly = @("whoami", "plan", "status", "logs", "cost", "sync", "help")
$Mutating = @("launch", "terminate", "promote")
$PinFile = Join-Path $HOME ".agents\hooks\paf-aws.sha256"

function Get-WrapperHash([string]$root) {
    $files = @(Get-Item -LiteralPath (Join-Path $root "scripts\paf-aws.ps1") -ErrorAction SilentlyContinue)
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
$json = $raw | ConvertFrom-Json

$isAgy = $null -ne $json.toolCall
if ($isAgy) {
    $cmd = $json.toolCall.args.CommandLine
    if ([string]::IsNullOrEmpty($cmd)) { $cmd = $json.toolCall.args.command }
} else {
    $cmd = $json.tool_input.command
}
$cwd = $json.cwd

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

if ([string]::IsNullOrEmpty($cmd)) { Exit-NoDecision }

$rawAws = '(?i)(^|[\s;&|(){}''"`=])aws(\.exe)?([''"]?)\s+\S'
if ($cmd -match $rawAws) {
    Out-Decision "deny" ("Raw aws CLI is off-limits for agents. Use scripts/paf-aws.ps1 (status/plan/logs/cost are allowed; " +
        "launch/terminate/promote need the user's approval), or give the user the exact command to run themselves.")
}
$credRead = '(?i)(\.aws[\\/]|[\\/]\.aws\b|AWS_SHARED_CREDENTIALS_FILE|AWS_CONFIG_FILE|export-credentials|\$env:AWS_|printenv\s+AWS_|sso[\\/]cache)'
if ($cmd -match $credRead) {
    Out-Decision "deny" "Agents never read AWS credential or config files, SSO caches or AWS_* variables."
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

$launcher = '((powershell|pwsh)(\.exe)?\s+(-(NoProfile|NonInteractive|ExecutionPolicy\s+Bypass)\s+)*-File\s+)?'
$single = '^\s*(&\s*)?' + $launcher + '[''"]?(\.[\\/])?scripts[\\/]paf-aws\.ps1[''"]?(?<args>(\s+[A-Za-z0-9._:/=,@+-]+)*)\s*$'
if ($cmd -notmatch $single) {
    Out-Decision "ask" "paf-aws.ps1 inside a compound or unusual command line: approve only if every part is expected."
}
$sub = (($Matches["args"].Trim() -split '\s+') | Select-Object -First 1).ToLower()

if ($Mutating -contains $sub) {
    Out-Decision "ask" "PAF cloud action '$sub': approve only if it matches the plan you approved in chat (plan id, jobs, cost)."
}
if ($ReadOnly -contains $sub) { Out-Decision "allow" "Read-only paf-aws subcommand." }
Out-Decision "ask" "Unknown paf-aws subcommand '$sub'."
