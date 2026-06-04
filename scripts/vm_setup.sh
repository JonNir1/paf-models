#!/usr/bin/env bash
# =============================================================================
# One-time R + EMC2 install on a fresh Ubuntu 22.04+ cloud VM.
# =============================================================================
# Run once after provisioning before launching any fit or recovery jobs.
# Assumes: Ubuntu 22.04+ LTS, sudo access, AWS CLI (or gcloud) installed.
#
# Usage:
#   ./scripts/vm_setup.sh
#
# Configure these env vars before running, or edit the defaults in helpers.sh:
#   BUCKET      - "my-paf-bucket"
#   CLOUD       - "aws" or "gcs"
#   REPO_URL    - "https://github.com/jonnir/paf-models.git"
#   REPO_DIR    - "/opt/paf-models"
#   R_LIBS_USER - "$HOME/R/library"
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive   # suppress all apt interactive prompts

source "$(dirname "$0")/helpers.sh"

echo ">>> Installing system deps..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  build-essential gfortran \
  libssl-dev libcurl4-openssl-dev libxml2-dev \
  libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
  libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
  libuv1-dev \
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
Rscript -e 'install.packages(
  c("EMC2","dplyr","readr","tools","testthat","loo","ggplot2","ragg"),
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
