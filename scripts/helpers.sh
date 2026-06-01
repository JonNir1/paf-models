#!/usr/bin/env bash
# =============================================================================
# Shared config defaults and cloud copy helpers.
# Source this from other scripts — do not run directly.
# =============================================================================

# --- USER CONFIG (override via env, or edit) ---------------------------------
: "${BUCKET:=TODO-bucket-name}"
: "${CLOUD:=aws}"     # or "gcs"
: "${REPO_URL:=TODO-repo-url}"
: "${REPO_DIR:=/opt/paf-models}"
: "${R_LIBS_USER:=$HOME/R/library}"

# cloud_cp_from <bucket-rel-src> <local-dst>
cloud_cp_from() {
  local src="$1" dst="$2"
  case "$CLOUD" in
    aws) aws s3 cp "s3://$BUCKET/$src" "$dst" ;;
    gcs) gsutil cp "gs://$BUCKET/$src"  "$dst" ;;
    *)   echo "Unknown CLOUD: $CLOUD" >&2; exit 1 ;;
  esac
}

# cloud_cp_to <local-src> <bucket-rel-dst>
cloud_cp_to() {
  local src="$1" dst="$2"
  case "$CLOUD" in
    aws) aws s3 cp "$src" "s3://$BUCKET/$dst" ;;
    gcs) gsutil cp "$src" "gs://$BUCKET/$dst" ;;
    *)   echo "Unknown CLOUD: $CLOUD" >&2; exit 1 ;;
  esac
}
