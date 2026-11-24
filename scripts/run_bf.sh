#!/usr/bin/env bash
# =============================================================================
# Download a fitted .rds from cloud storage, compute its bridge-sampling log
# marginal likelihood via fit_bf_cloud.R, and sync the MLL file back.
# =============================================================================
# Assumes: vm_setup.sh has already been run on this machine.
#
# Usage:
#   ./scripts/run_bf.sh <fitted_rds> [extra args forwarded to fit_bf_cloud.R]
# Example:
#   ./scripts/run_bf.sh 260618_mymodel.rds
#   ./scripts/run_bf.sh 260618_mymodel.rds --reps 10
# A recovery fit (for model recovery) lives under results/recovery/ instead:
#   FIT_PREFIX=results/recovery FIT_DIR=outputs/models/fit_recovery \
#     ./scripts/run_bf.sh 260618_mymodel_recovery_sim1_fit_other.rds
#
# Configure these env vars before running, or edit the defaults in helpers.sh:
#   BUCKET     - "paf-models"
#   CLOUD      - "aws" or "gcs"
#   REPO_DIR   - "/opt/paf-models"
#   FIT_PREFIX - bucket folder holding the fit (default inputs/fit)
#   FIT_DIR    - local folder to download it to (default outputs/models/fit)
# =============================================================================

set -euo pipefail

source "$(dirname "$0")/helpers.sh"

rds_name="${1:?usage: run_bf.sh <fitted_rds>}"
shift   # remaining args (if any) forwarded to fit_bf_cloud.R

: "${FIT_PREFIX:=inputs/fit}"
: "${FIT_DIR:=outputs/models/fit}"

cd "$REPO_DIR"

if [ "$CLOUD" = "aws" ]; then
  CP_CMD="aws s3 cp"
  DEST_PREFIX="s3://$BUCKET/results/bf"
else
  CP_CMD="gsutil cp"
  DEST_PREFIX="gs://$BUCKET/results/bf"
fi

echo ">>> Downloading inputs from $BUCKET ..."
mkdir -p "$FIT_DIR" outputs/models/fit_bf
cloud_cp_from "$FIT_PREFIX/$rds_name" "$FIT_DIR/$rds_name"

echo ">>> Launching fit_bf_cloud.R for $rds_name ..."
R_LIBS_USER="$R_LIBS_USER" CP_CMD="$CP_CMD" DEST_PREFIX="$DEST_PREFIX" \
  Rscript R/fit/fit_bf_cloud.R "$FIT_DIR/$rds_name" "$@"

echo ">>> Done. Results in $BUCKET/results/bf/."
