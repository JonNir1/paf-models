# =============================================================================
# paf-r: runtime image for PAF EMC2 jobs on AWS Batch.
#
# Contains only the toolchain (R, R packages, cloud CLI, git). No secrets, no
# data and no repo code are baked in: `paf-bootstrap` clones the repo at the
# commit named by PAF_GIT_SHA at container start (see paf-bootstrap.sh).
#
# Reproducibility pins:
#   - base image: rocker/r-ver tag AND manifest-list digest
#   - R packages: dated Posit Package Manager snapshot (RSPM_DATE); the build
#     fails unless EMC2 resolves to exactly 3.5.0
#   - CLI v2 (AWSCLI_VERSION): exact version + SHA-256 of the official zip
# =============================================================================
FROM rocker/r-ver:4.5.2@sha256:fd4ccdd3a4a6f7ef805e2daeee2a0fe3bf126bc231f36351223baecf5a595a4c

ARG UBUNTU_CODENAME=noble
ARG RSPM_DATE=2026-11-01
ARG AWSCLI_VERSION=2.42.3
ARG AWSCLI_SHA256_X86_64=09a4a71458061ce4e6e8c1ddbeb5d128c219ef7c9906b7b92c3b542944c025c8
ARG AWSCLI_SHA256_AARCH64=7c512283f5293c6fb0832ad648198993185889b22ea8b19bcd04c153dabc8643

LABEL org.opencontainers.image.source="https://github.com/JonNir1/paf-models" \
      org.opencontainers.image.description="R + EMC2 runtime for PAF model fitting on AWS Batch (no code or data baked in)"

ENV DEBIAN_FRONTEND=noninteractive

# System packages: git/curl/unzip/ca-certificates for the bootstrap and the CLI
# install, plus the build toolchain and system libs scripts/vm_setup.sh installs
# (Ubuntu 24.04 names: libtiff-dev replaces libtiff5-dev).
RUN . /etc/os-release \
 && if [ "$VERSION_CODENAME" != "$UBUNTU_CODENAME" ]; then \
      echo "base image is $VERSION_CODENAME, expected $UBUNTU_CODENAME: update UBUNTU_CODENAME" >&2; exit 1; \
    fi \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential gfortran \
      libssl-dev libcurl4-openssl-dev libxml2-dev \
      libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
      libfreetype6-dev libpng-dev libtiff-dev libjpeg-dev \
      libuv1-dev \
      git curl unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 from the official zip, verified against a pinned SHA-256.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64)  sha="$AWSCLI_SHA256_X86_64" ;; \
      aarch64) sha="$AWSCLI_SHA256_AARCH64" ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    cd "$(mktemp -d)"; \
    curl -fsSL -o awscliv2.zip "https://awscli.amazonaws.com/awscli-exe-linux-${arch}-${AWSCLI_VERSION}.zip"; \
    echo "${sha}  awscliv2.zip" | sha256sum -c -; \
    unzip -q awscliv2.zip; \
    ./aws/install; \
    cd /; \
    aws --version

# R packages from a dated snapshot (RSPM serves binaries given the HTTPUserAgent).
# `tools` is part of base R, so it is loaded but not installed. install.packages()
# only warns when a package fails, hence the explicit load + version assertions.
RUN RSPM_URL="https://packagemanager.posit.co/cran/__linux__/${UBUNTU_CODENAME}/${RSPM_DATE}" \
    Rscript -e ' \
      options(HTTPUserAgent = sprintf("R/%s R (%s)", getRversion(), paste(getRversion(), R.version["platform"], R.version["arch"], R.version["os"]))); \
      pkgs <- c("EMC2", "dplyr", "readr", "testthat", "loo", "ggplot2", "ragg", "jsonlite"); \
      install.packages(pkgs, repos = c(CRAN = Sys.getenv("RSPM_URL")), dependencies = c("Depends", "Imports", "LinkingTo")); \
      for (p in c(pkgs, "tools")) library(p, character.only = TRUE); \
      stopifnot(as.character(packageVersion("EMC2")) == "3.5.0"); \
      cat("EMC2", as.character(packageVersion("EMC2")), "OK\n")'

COPY paf-bootstrap.sh /usr/local/bin/paf-bootstrap
RUN chmod 0755 /usr/local/bin/paf-bootstrap

# Non-root runtime user; /opt/paf-models is where the bootstrap clones the repo.
RUN useradd --create-home --uid 10001 --shell /bin/bash paf \
 && mkdir /opt/paf-models \
 && chown paf:paf /opt/paf-models

USER paf
WORKDIR /home/paf
CMD ["paf-bootstrap"]
