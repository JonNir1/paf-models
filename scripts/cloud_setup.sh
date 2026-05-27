#!/usr/bin/env bash
# =============================================================================
# Cloud-instance bootstrap for paf-models EMC2 fits (AWS / GCS)
# =============================================================================
# Run as the EC2/GCE startup script, or manually after `ssh` into a fresh VM.
# Assumes: Ubuntu 22.04+ LTS, 8+ vCPU, 16+ GB RAM, AWS CLI (or gcloud) already
# installed and credentials configured (via IAM role or `aws configure`).
#
# Usage:
#   ./scripts/cloud_setup.sh setup            # one-time R + EMC2 install
#   ./scripts/cloud_setup.sh run <rds_name>   # download inputs, run extend, sync
#   ./scripts/cloud_setup.sh recovery <rds_name> <sim_index>
#
# Expects the following bucket layout (S3 example; GCS analogous):
#   s3://$BUCKET/inputs/data/emc2_design_matrix.csv
#   s3://$BUCKET/inputs/fit_initial/<initial>.rds    (one per model)
#   s3://$BUCKET/inputs/fit_extend/<extended>.rds    (recovery input)
#   s3://$BUCKET/results/                             (this is where outputs land)
#
# Configure these env vars before running, or edit the defaults below:
#   BUCKET   - "my-paf-bucket"   (S3 bucket name, no s3:// prefix)
#   CLOUD    - "aws" or "gcs"    (which CLI to use for transfers)
#   REPO_URL - "https://github.com/jonnir/paf-models.git"
#   REPO_DIR - "/opt/paf-models"
# =============================================================================

set -euo pipefail

# --- USER CONFIG (override via env, or edit) ---------------------------------
: "${BUCKET:=TODO-bucket-name}"
: "${CLOUD:=aws}"     # or "gcs"
: "${REPO_URL:=TODO-repo-url}"
: "${REPO_DIR:=/opt/paf-models}"
: "${R_LIBS_USER:=$HOME/R/library}"

# Helper: cloud-agnostic cp wrappers
cloud_cp_from() {  # cloud_cp_from <bucket-rel-src> <local-dst>
  local src="$1" dst="$2"
  case "$CLOUD" in
    aws) aws s3 cp "s3://$BUCKET/$src" "$dst" ;;
    gcs) gsutil cp "gs://$BUCKET/$src"  "$dst" ;;
    *)   echo "Unknown CLOUD: $CLOUD" >&2; exit 1 ;;
  esac
}
cloud_cp_to() {    # cloud_cp_to <local-src> <bucket-rel-dst>
  local src="$1" dst="$2"
  case "$CLOUD" in
    aws) aws s3 cp "$src" "s3://$BUCKET/$dst" ;;
    gcs) gsutil cp "$src" "gs://$BUCKET/$dst" ;;
  esac
}

# --- setup: one-time R + EMC2 install ----------------------------------------
do_setup() {
  echo ">>> Installing system deps..."
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends \
    build-essential gfortran \
    libssl-dev libcurl4-openssl-dev libxml2-dev \
    libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
    libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
    git curl unzip software-properties-common awscli

  echo ">>> Installing R 4.4 from CRAN apt repo..."
  wget -qO- https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
    | sudo tee -a /etc/apt/trusted.gpg.d/cran_ubuntu_key.asc
  sudo add-apt-repository -y "deb https://cloud.r-project.org/bin/linux/ubuntu jammy-cran40/"
  sudo apt-get update -y
  sudo apt-get install -y r-base r-base-dev

  mkdir -p "$R_LIBS_USER"
  echo "R_LIBS_USER=\"$R_LIBS_USER\"" >> "$HOME/.Renviron"

  echo ">>> Installing R packages via RSPM pre-compiled binaries (~2 min)..."
  Rscript -e 'options(pkgType="binary"); install.packages(
    c("EMC2","dplyr","readr","tools","testthat"),
    repos      = "https://packagemanager.posit.co/cran/__linux__/jammy/latest",
    dependencies = c("Depends","Imports","LinkingTo")
  )'

  echo ">>> Cloning repo..."
  if [ ! -d "$REPO_DIR" ]; then
    sudo git clone "$REPO_URL" "$REPO_DIR"
    sudo chown -R "$USER:$USER" "$REPO_DIR"
  fi

  echo ">>> Setup complete. Quick sanity check:"
  Rscript -e 'suppressMessages(library(EMC2)); cat("EMC2 OK:", as.character(packageVersion("EMC2")), "\n")'
}

# --- recovery: download extended model, run one recovery sim, sync outputs ---
# Usage: ./cloud_setup.sh recovery <extended_rds> <sim_index> [extra args...]
# Example: ./cloud_setup.sh recovery 260525_model1_extended.rds 1
do_recovery() {
  local rds_name="${1:?usage: recovery <extended_rds> <sim_index>}"
  local sim_index="${2:?usage: recovery <extended_rds> <sim_index>}"
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
  mkdir -p outputs/models/fit_extend outputs/models/fit_recovery data
  cloud_cp_from "inputs/fit_extend/$rds_name" "outputs/models/fit_extend/$rds_name"
  cloud_cp_from "inputs/data/emc2_design_matrix.csv" "data/emc2_design_matrix.csv"

  echo ">>> Launching fit_recovery_cloud.R for $rds_name sim=$sim_index ..."
  R_LIBS_USER="$R_LIBS_USER" CP_CMD="$CP_CMD" DEST_PREFIX="$DEST_PREFIX" \
    Rscript R/fit/fit_recovery_cloud.R "$rds_name" "$sim_index" "$@"

  echo ">>> Done. Results in $BUCKET/results/recovery/."
}


# --- run: download inputs, fit one model, sync outputs -----------------------
# Any arguments after <rds_filename> are forwarded verbatim to fit_extend_cloud.R.
# Example: ./cloud_setup.sh run 260421_model1.rds --max-tries 3 --step-size 5
do_run() {
  local rds_name="${1:?usage: run <rds_filename, e.g. 260421_model1.rds>}"
  shift   # remaining args (if any) forwarded to Rscript below
  cd "$REPO_DIR"

  # Resolve cloud copy command and destination prefix upfront so they expand as
  # plain strings inside the R script string — avoids nested $() substitutions
  # and quote conflicts inside the Rscript -e "..." double-quoted block.
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
}

# --- entry point -------------------------------------------------------------
case "${1:-help}" in
  setup)    do_setup ;;
  run)      shift; do_run "$@" ;;
  recovery) shift; do_recovery "$@" ;;
  *)        echo "Usage: $0 setup|run <rds_filename>|recovery <extended_rds> <sim_index>"; exit 1 ;;
esac
