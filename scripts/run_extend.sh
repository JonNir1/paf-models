#!/usr/bin/env bash
# =============================================================================
# Download an initial-fit .rds from cloud storage, run fit_extend_cloud.R,
# and sync outputs back after every checkpoint.
# =============================================================================
# Assumes: vm_setup.sh has already been run on this machine.
#
# Usage:
#   ./scripts/run_extend.sh <rds_filename> [extra args forwarded to fit_extend_cloud.R]
# Example:
#   ./scripts/run_extend.sh 260421_model1.rds --max-tries 3 --step-size 5
#
# Configure these env vars before running, or edit the defaults in helpers.sh:
#   BUCKET   - "my-paf-bucket"
#   CLOUD    - "aws" or "gcs"
#   REPO_DIR - "/opt/paf-models"
# =============================================================================

set -euo pipefail

source "$(dirname "$0")/helpers.sh"

rds_name="${1:?usage: run_extend.sh <rds_filename, e.g. 260421_model1.rds>}"
shift   # remaining args (if any) forwarded to Rscript below

cd "$REPO_DIR"

# Resolve cloud copy command and destination prefix upfront so they expand as
# plain strings inside the R script — avoids nested $() substitutions and
# quote conflicts inside Rscript -e "..." double-quoted blocks.
if [ "$CLOUD" = "aws" ]; then
  CP_CMD="aws s3 cp"
  DEST_PREFIX="s3://$BUCKET/results"
else
  CP_CMD="gsutil cp"
  DEST_PREFIX="gs://$BUCKET/results"
fi

echo ">>> Downloading inputs from $BUCKET ..."
mkdir -p outputs/models/fit_initial outputs/models/fit_extend
cloud_cp_from "inputs/fit_initial/$rds_name" "outputs/models/fit_initial/$rds_name"

echo ">>> Launching fit_extend_cloud.R for $rds_name ..."
# fit_extend_cloud.R reads CP_CMD and DEST_PREFIX from the environment and
# syncs the .rds + log to durable storage every SAVE_EVERY tries (fit_config.R).
R_LIBS_USER="$R_LIBS_USER" CP_CMD="$CP_CMD" DEST_PREFIX="$DEST_PREFIX" \
  Rscript R/fit/fit_extend_cloud.R "$rds_name" "$@"

echo ">>> Done. Latest .rds and log are in $BUCKET/results/."
