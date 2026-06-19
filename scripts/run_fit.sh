#!/usr/bin/env bash
# =============================================================================
# Run the unified fit pipeline (R/fit/fit_cloud.R) on a cloud VM and sync
# outputs back after every checkpoint. Replaces the retired run_extend.sh.
# =============================================================================
# Assumes: vm_setup.sh has already been run on this machine.
#
# Two modes (mirror fit_cloud.R):
#   # Build a fresh model from a definition script and fit to convergence:
#   ./scripts/run_fit.sh --model-script R/fit/mymodel.R [extra args]
#   # Resume a saved fit (filename only; downloaded from inputs/fit/):
#   ./scripts/run_fit.sh --resume 260618_mymodel.rds [extra args]
#
# Configure these env vars before running, or edit the defaults in helpers.sh:
#   BUCKET   - "my-paf-bucket"
#   CLOUD    - "aws" or "gcs"
#   REPO_DIR - "/opt/paf-models"
# =============================================================================

set -euo pipefail

source "$(dirname "$0")/helpers.sh"

cd "$REPO_DIR"

# --- Scan args to decide what inputs to fetch (args are forwarded verbatim) ---
mode=""
resume_name=""
prev=""
for a in "$@"; do
  case "$prev" in
    --resume)       mode="resume"; resume_name="$a" ;;
    --model-script) mode="fresh" ;;
  esac
  prev="$a"
done
[ -n "$mode" ] || { echo "usage: run_fit.sh (--model-script <path> | --resume <rds>) [extra args]" >&2; exit 1; }

# Resolve cloud copy command + destination prefix upfront (plain strings for R).
if [ "$CLOUD" = "aws" ]; then
  CP_CMD="aws s3 cp"
  DEST_PREFIX="s3://$BUCKET/results/fit"
else
  CP_CMD="gsutil cp"
  DEST_PREFIX="gs://$BUCKET/results/fit"
fi

mkdir -p outputs/models/fit

if [ "$mode" = "resume" ]; then
  echo ">>> Downloading $resume_name from $BUCKET/inputs/fit ..."
  cloud_cp_from "inputs/fit/$resume_name" "outputs/models/fit/$resume_name"
else
  echo ">>> Downloading raw experiment data from $BUCKET/inputs/data ..."
  mkdir -p data/exp1 data/exp2
  cloud_cp_from "inputs/data/exp1/Exp1_clean.csv" "data/exp1/Exp1_clean.csv"
  cloud_cp_from "inputs/data/exp2/Exp2_clean.csv" "data/exp2/Exp2_clean.csv"
fi

echo ">>> Launching fit_cloud.R ..."
# fit_cloud.R reads CP_CMD and DEST_PREFIX from the environment and syncs the
# .rds + log to durable storage every SAVE_EVERY tries (fit_config.R).
R_LIBS_USER="$R_LIBS_USER" CP_CMD="$CP_CMD" DEST_PREFIX="$DEST_PREFIX" \
  Rscript R/fit/fit_cloud.R "$@"

echo ">>> Done. Latest .rds and log are in $BUCKET/results/fit/."
