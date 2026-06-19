#!/usr/bin/env bash
# =============================================================================
# Download an extended-fit .rds from cloud storage, run the PPC simulation
# via fit_ppc_cloud.R, and sync outputs back.
# =============================================================================
# Assumes: vm_setup.sh has already been run on this machine.
#
# Usage:
#   ./scripts/run_ppc.sh <fitted_rds> [extra args forwarded to fit_ppc_cloud.R]
# Example:
#   ./scripts/run_ppc.sh 260618_mymodel.rds
#   ./scripts/run_ppc.sh 260618_mymodel.rds --n-draws 20
#   ./scripts/run_ppc.sh 260618_mymodel.rds --save-every 50
#
# Configure these env vars before running, or edit the defaults in helpers.sh:
#   BUCKET   - "paf-models"
#   CLOUD    - "aws" or "gcs"
#   REPO_DIR - "/opt/paf-models"
# =============================================================================

set -euo pipefail

source "$(dirname "$0")/helpers.sh"

rds_name="${1:?usage: run_ppc.sh <fitted_rds>}"
shift   # remaining args (if any) forwarded to fit_ppc_cloud.R

cd "$REPO_DIR"

if [ "$CLOUD" = "aws" ]; then
  CP_CMD="aws s3 cp"
  DEST_PREFIX="s3://$BUCKET/results/ppc"
else
  CP_CMD="gsutil cp"
  DEST_PREFIX="gs://$BUCKET/results/ppc"
fi

echo ">>> Downloading inputs from $BUCKET ..."
mkdir -p outputs/models/fit outputs/models/fit_ppc data/exp1 data/exp2
cloud_cp_from "inputs/fit/$rds_name" "outputs/models/fit/$rds_name"
cloud_cp_from "inputs/data/exp1/Exp1_clean.csv" "data/exp1/Exp1_clean.csv"
cloud_cp_from "inputs/data/exp2/Exp2_clean.csv" "data/exp2/Exp2_clean.csv"

echo ">>> Launching fit_ppc_cloud.R for $rds_name ..."
R_LIBS_USER="$R_LIBS_USER" CP_CMD="$CP_CMD" DEST_PREFIX="$DEST_PREFIX" \
  Rscript R/fit/fit_ppc_cloud.R "$rds_name" "$@"

echo ">>> Done. Results in $BUCKET/results/ppc/."
