# Shim for the agent-facing AWS Batch wrapper. Usage: scripts\paf-aws.ps1 <subcommand> [args...]
# Runs from the repo root (the parent of this scripts/ folder) with the user's R library.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$env:R_LIBS_USER = "C:\Users\nirjo\R_library\4.5"
$env:PAF_REPO_ROOT = $root
Push-Location $root
try {
    & Rscript R/cloud/paf_aws.R @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
