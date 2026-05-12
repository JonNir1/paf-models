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
#
# Expects the following bucket layout (S3 example; GCS analogous):
#   s3://$BUCKET/inputs/data/emc2_design_matrix.csv
#   s3://$BUCKET/inputs/emc2_models/<initial>.rds   (one per model)
#   s3://$BUCKET/results/                            (this is where outputs land)
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
    r-base r-base-dev \
    build-essential gfortran \
    libssl-dev libcurl4-openssl-dev libxml2-dev \
    libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
    libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
    git curl unzip

  mkdir -p "$R_LIBS_USER"
  echo "R_LIBS_USER=\"$R_LIBS_USER\"" >> "$HOME/.Renviron"

  echo ">>> Installing R packages (this takes 10-20 min on a fresh VM)..."
  Rscript -e 'install.packages(c("EMC2","dplyr","readr","tools"),
                                repos="https://cloud.r-project.org")'

  echo ">>> Cloning repo..."
  if [ ! -d "$REPO_DIR" ]; then
    sudo git clone "$REPO_URL" "$REPO_DIR"
    sudo chown -R "$USER:$USER" "$REPO_DIR"
  fi

  echo ">>> Setup complete. Quick sanity check:"
  Rscript -e 'suppressMessages(library(EMC2)); cat("EMC2 OK:", as.character(packageVersion("EMC2")), "\n")'
}

# --- run: download inputs, fit one model, sync outputs -----------------------
do_run() {
  local rds_name="${1:?usage: run <rds_filename, e.g. 260421_model1.rds>}"
  cd "$REPO_DIR"

  echo ">>> Downloading inputs from $BUCKET ..."
  mkdir -p data emc2_models
  cloud_cp_from "inputs/data/emc2_design_matrix.csv" "data/emc2_design_matrix.csv"
  cloud_cp_from "inputs/emc2_models/$rds_name"       "emc2_models/$rds_name"

  echo ">>> Launching fit_extend for $rds_name ..."
  # Inline R: source the script (sys.nframe guard avoids triggering main logic),
  # then call extend_model with save_every=1 and a hook that uploads both the
  # .rds and the log to s3://$BUCKET/results/ after every save.
  R_LIBS_USER="$R_LIBS_USER" Rscript -e "
    source('R/model_fitting/fit_extend.R')
    hook <- function(rds_path, log_path) {
      for (f in c(rds_path, log_path)) {
        cmd <- sprintf('$( [ \"$CLOUD\" = aws ] && echo 'aws s3 cp' || echo 'gsutil cp' ) %s $( [ \"$CLOUD\" = aws ] && echo s3:// || echo gs:// )$BUCKET/results/', shQuote(f))
        system(cmd, wait = TRUE)
      }
    }
    res <- extend_model(
      rds_filename   = '$rds_name',
      log_file       = file.path('emc2_models', paste0('log_extend_', tools::file_path_sans_ext('$rds_name'), '.txt')),
      save_every     = 1,
      post_save_hook = hook
    )
    cat('\n=== done ===\nconverged:', res\$converged,
        '\nruntime_min:', round(res\$duration_min, 2),
        '\nsaved:', res\$saved_path, '\n')
  "

  echo ">>> Done. Latest .rds and log are in $BUCKET/results/."
}

# --- entry point -------------------------------------------------------------
case "${1:-help}" in
  setup) do_setup ;;
  run)   shift; do_run "$@" ;;
  *)     echo "Usage: $0 setup|run <rds_filename>"; exit 1 ;;
esac
