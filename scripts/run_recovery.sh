#!/usr/bin/env bash
# =============================================================================
# Download an extended-fit .rds from cloud storage, run one parameter-recovery
# simulation via fit_recovery_cloud.R, and sync outputs back.
# =============================================================================
# Assumes: vm_setup.sh has already been run on this machine.
#
# Usage:
#   ./scripts/run_recovery.sh <fitted_rds> <sim_index> [extra args forwarded to fit_recovery_cloud.R]
# Example:
#   ./scripts/run_recovery.sh 260618_mymodel.rds 1
#
# Configure these env vars before running, or edit the defaults in helpers.sh:
#   BUCKET   - "my-paf-bucket"
#   CLOUD    - "aws" or "gcs"
#   REPO_DIR - "/opt/paf-models"
# =============================================================================

set -euo pipefail

source "$(dirname "$0")/helpers.sh"

rds_name="${1:?usage: run_recovery.sh <fitted_rds> <sim_index>}"
sim_index="${2:?usage: run_recovery.sh <fitted_rds> <sim_index>}"
shift 2   # remaining args (if any) forwarded to fit_recovery_cloud.R

cd "$REPO_DIR"

if [ "$CLOUD" = "aws" ]; then
  CP_CMD="aws s3 cp"
  DEST_PREFIX="s3://$BUCKET/results/recovery"
else
  CP_CMD="gsutil cp"
  DEST_PREFIX="gs://$BUCKET/results/recovery"
fi

echo ">>> Downloading inputs from $BUCKET ..."
mkdir -p outputs/models/fit outputs/models/fit_recovery data/exp1 data/exp2
cloud_cp_from "inputs/fit/$rds_name" "outputs/models/fit/$rds_name"
cloud_cp_from "inputs/data/exp1/Exp1_clean.csv" "data/exp1/Exp1_clean.csv"
cloud_cp_from "inputs/data/exp2/Exp2_clean.csv" "data/exp2/Exp2_clean.csv"

echo ">>> Launching fit_recovery_cloud.R for $rds_name sim=$sim_index ..."
R_LIBS_USER="$R_LIBS_USER" CP_CMD="$CP_CMD" DEST_PREFIX="$DEST_PREFIX" \
  Rscript R/fit/fit_recovery_cloud.R "$rds_name" "$sim_index" "$@"

echo ">>> Done. Results in $BUCKET/results/recovery/."
