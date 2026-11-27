#!/usr/bin/env bash
# =============================================================================
# Container CMD for the paf-r image (AWS Batch job definition `paf-job`).
# Clones the repo at the exact commit named by PAF_GIT_SHA, then hands over to
# scripts/batch_entrypoint.sh from that commit. No code is baked into the image:
# what runs is whatever the pinned commit contains.
# =============================================================================
set -euo pipefail

readonly REPO_URL="https://github.com/JonNir1/paf-models.git"
readonly REPO_DIR="/opt/paf-models"

sha="${PAF_GIT_SHA:-}"
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "paf-bootstrap: PAF_GIT_SHA must be a full 40-character lowercase hex commit SHA" >&2
  exit 2
fi

export GIT_TERMINAL_PROMPT=0

echo ">>> Cloning $REPO_URL into $REPO_DIR ..."
git clone --quiet "$REPO_URL" "$REPO_DIR"
git -C "$REPO_DIR" checkout --quiet --detach "$sha"

head_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
if [ "$head_sha" != "$sha" ]; then
  echo "paf-bootstrap: checked-out HEAD $head_sha does not match PAF_GIT_SHA $sha" >&2
  exit 2
fi
echo ">>> Checked out $head_sha"

entry="$REPO_DIR/scripts/batch_entrypoint.sh"
if [ ! -f "$entry" ]; then
  echo "paf-bootstrap: $entry not found at commit $sha" >&2
  exit 2
fi

exec bash "$entry"
