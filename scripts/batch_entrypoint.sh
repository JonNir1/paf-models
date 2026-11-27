#!/usr/bin/env bash
# =============================================================================
# AWS Batch entrypoint: dispatches one job to the existing run_*.sh scripts.
# =============================================================================
# Started by `paf-bootstrap` (infra/docker/) inside the paf-r image, after the
# repo was cloned at PAF_GIT_SHA into /opt/paf-models. Job parameters arrive as
# container env vars (the wrapper never overrides the command):
#
#   PAF_KIND         smoke | fit | resume | recovery | bf | ppc      (required)
#   PAF_ARGS         whitespace-separated args forwarded to the run script;
#                    every token must match [A-Za-z0-9._/=-]
#   BUCKET           bucket + prefix root (default jon-nir/paf-models)
#   FIT_PREFIX / FIT_DIR   bf only: where the fit lives (see run_bf.sh)
#   PT_PRIOR_SD_SCALE      optional, passed through to the model scripts
#   PAF_RUN_ID       informational (logged)
#
# Dispatch:
#   fit      -> run_fit.sh --model-script $PAF_ARGS
#   resume   -> run_fit.sh --resume $PAF_ARGS
#   recovery -> run_recovery.sh $PAF_ARGS
#   bf       -> run_bf.sh $PAF_ARGS
#   ppc      -> run_ppc.sh $PAF_ARGS
#   smoke    -> L1 tests + report to S3 + check the job role is prefix-scoped
#
# Spot retry: when AWS_BATCH_JOB_ATTEMPT > 1 and the kind is `fit` or `resume`, the newest
# results/fit/<YYMMDD>_<model>.rds checkpoint is copied to inputs/fit/ and the
# job resumes from it. This needs s3:ListBucket on the results/fit/ prefix; if
# listing fails the job warns and refits from scratch.
#
# The whole job output is teed to a log that is uploaded to
# results/logs/<AWS_BATCH_JOB_ID>.log on every exit path (also on SIGTERM).
# Exit codes: 2 = invalid parameters; otherwise the dispatched script's status.
# =============================================================================

set -euo pipefail
set -m   # background job in its own process group, so signals reach all its children

: "${BUCKET:=jon-nir/paf-models}"
: "${REPO_DIR:=/opt/paf-models}"
export BUCKET REPO_DIR
export CLOUD=aws

JOB_ID="${AWS_BATCH_JOB_ID:-local}"
LOG_FILE="${TMPDIR:-/tmp}/paf_job.log"
BUCKET_ROOT="${BUCKET%%/*}"

ARGS=()   # validated PAF_ARGS tokens

die() {
  echo "batch_entrypoint: $*" >&2
  exit 2
}

validate_env() {
  [[ "$JOB_ID" =~ ^[A-Za-z0-9_-]+$ ]] || die "AWS_BATCH_JOB_ID has unexpected characters"
  [[ "$BUCKET" =~ ^[A-Za-z0-9._/-]+$ ]] || die "BUCKET has unexpected characters"

  case "${PAF_KIND:-}" in
    smoke | fit | resume | recovery | bf | ppc) ;;
    *) die "PAF_KIND must be one of smoke|fit|resume|recovery|bf|ppc (got '${PAF_KIND:-}')" ;;
  esac

  local tok
  IFS=$' \t\n' read -r -d '' -a ARGS <<< "${PAF_ARGS:-}" || true
  for tok in ${ARGS[@]+"${ARGS[@]}"}; do
    [[ "$tok" =~ ^[A-Za-z0-9._/=-]+$ ]] || die "PAF_ARGS token '$tok' has characters outside [A-Za-z0-9._/=-]"
    [[ "$tok" != *..* ]] || die "PAF_ARGS token '$tok' contains '..'"
  done

  if [ -n "${FIT_PREFIX:-}" ]; then
    [[ "$FIT_PREFIX" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$FIT_PREFIX" != *..* ]] \
      || die "FIT_PREFIX must be a relative path of [A-Za-z0-9._-] segments"
  fi
  if [ -n "${FIT_DIR:-}" ]; then
    [[ "$FIT_DIR" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$FIT_DIR" != *..* ]] \
      || die "FIT_DIR must be a relative path of [A-Za-z0-9._-] segments"
  fi
  if [ -n "${PT_PRIOR_SD_SCALE:-}" ]; then
    local num_re='^([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$'
    [[ "$PT_PRIOR_SD_SCALE" =~ $num_re ]] \
      || die "PT_PRIOR_SD_SCALE must be a non-negative number"
    export PT_PRIOR_SD_SCALE
  fi

  case "$PAF_KIND" in
    fit | resume | bf | ppc) [ "${#ARGS[@]}" -ge 1 ] || die "PAF_ARGS is required for kind '$PAF_KIND'" ;;
    recovery) [ "${#ARGS[@]}" -ge 2 ] || die "PAF_ARGS must start with '<rds> <sim_index>' for kind recovery" ;;
  esac
}

# MODEL_NAME declared at top level of a model script, else the script basename.
model_name_of() {
  local script="$1" name=""
  if [ -f "$script" ]; then
    name="$(sed -nE "/^MODEL_NAME[[:space:]]*(<-|=)/{s/^MODEL_NAME[[:space:]]*(<-|=)[[:space:]]*[\"']([A-Za-z0-9._-]+)[\"'].*/\\2/p;q}" "$script")"
  fi
  [ -n "$name" ] || name="$(basename "$script" .R)"
  printf '%s' "$name"
}

# Newest results/fit/<YYMMDD>_<stem>.rds name in S3; empty if none or listing fails.
newest_checkpoint() {
  local stem="$1" re listing
  re="^[0-9]{6}_${stem//./\\.}\\.rds\$"
  listing="$(aws s3 ls "s3://$BUCKET/results/fit/")" || {
    echo "WARN: could not list s3://$BUCKET/results/fit/ (nothing there yet, or the job role lacks s3:ListBucket)" >&2
    return 0
  }
  printf '%s\n' "$listing" | awk '{print $4}' | { grep -E "$re" || true; } | sort | tail -n 1
}

# Model name of a fit file, as model_name_from_rds() (R/eval/helpers/io.R): no dir,
# no .rds, no YYMMDD_ prefix, no trailing _extended.
rds_model_name() {
  local name
  name="$(basename "$1" .rds)"
  name="${name#[0-9][0-9][0-9][0-9][0-9][0-9]_}"
  while [[ "$name" == *_extended ]]; do name="${name%_extended}"; done
  printf '%s' "$name"
}

# fit and resume kinds. On a spot retry (attempt > 1) both continue from the newest
# results/fit/<YYMMDD>_<model><suffix>.rds checkpoint (fit_cloud.R's save name), so
# the paid iterations of earlier attempts are kept. A resume only switches to a
# checkpoint dated on or after its input, never back to an older fit. --suffix is
# dropped on that path: the checkpoint name already carries it.
run_fit_kind() {
  local first="${ARGS[0]}" attempt="${AWS_BATCH_JOB_ATTEMPT:-1}"
  local rest=("${ARGS[@]:1}")
  local fresh_flag="--model-script"
  [ "$PAF_KIND" = "resume" ] && fresh_flag="--resume"

  if [[ "$attempt" =~ ^[0-9]+$ ]] && (( attempt > 1 )); then
    local suffix="" kept=() i
    for ((i = 0; i < ${#rest[@]}; i++)); do
      if [ "${rest[i]}" = "--suffix" ] && (( i + 1 < ${#rest[@]} )); then
        suffix="${rest[i+1]}"
        i=$((i + 1))
        continue
      fi
      kept+=("${rest[i]}")
    done

    local stem ckpt
    if [ "$PAF_KIND" = "resume" ]; then
      stem="$(rds_model_name "$first")$suffix"
    else
      stem="$(model_name_of "$REPO_DIR/$first")$suffix"
    fi
    ckpt="$(newest_checkpoint "$stem")"
    if [ -n "$ckpt" ] && [ "$PAF_KIND" = "resume" ]; then
      local in_date="${first:0:6}"
      if [[ "$in_date" =~ ^[0-9]{6}$ ]] && (( 10#${ckpt:0:6} < 10#$in_date )); then
        echo ">>> Attempt $attempt: newest checkpoint $ckpt predates input $first; keeping the input"
        ckpt=""
      fi
    fi
    if [ -n "$ckpt" ]; then
      echo ">>> Attempt $attempt: resuming from checkpoint s3://$BUCKET/results/fit/$ckpt"
      aws s3 cp "s3://$BUCKET/results/fit/$ckpt" "s3://$BUCKET/inputs/fit/$ckpt" --only-show-errors
      "$REPO_DIR/scripts/run_fit.sh" --resume "$ckpt" ${kept[@]+"${kept[@]}"}
      return
    fi
    echo ">>> Attempt $attempt: no usable checkpoint for '$stem'; restarting from the original arguments"
  fi

  "$REPO_DIR/scripts/run_fit.sh" "$fresh_flag" "${ARGS[@]}"
}

run_smoke() {
  cd "$REPO_DIR"
  local ts report test_out probe test_rc=0 probe_status probe_rc=0
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  report="$(mktemp)"
  test_out="$(mktemp)"
  probe="$(mktemp)"

  echo ">>> Running L1 tests"
  Rscript __tests__/run_tests.R 2>&1 | tee "$test_out" || test_rc="${PIPESTATUS[0]}"

  echo ">>> Checking the job role is scoped to the $BUCKET prefix"
  echo "paf scope probe $ts $JOB_ID" > "$probe"
  local probe_err
  probe_err="$(mktemp)"
  if aws s3 cp "$probe" "s3://$BUCKET_ROOT/_paf_scope_probe.txt" --only-show-errors 2> "$probe_err"; then
    probe_status="FAIL: write to s3://$BUCKET_ROOT/_paf_scope_probe.txt SUCCEEDED (role is not prefix-scoped; delete that object manually)"
    probe_rc=1
  elif grep -qiE "AccessDenied|Forbidden|403" "$probe_err"; then
    probe_status="PASS: write outside the prefix was denied"
  else
    probe_status="INCONCLUSIVE: write failed but not with an access error: $(head -c 300 "$probe_err")"
    probe_rc=1
  fi
  echo "$probe_status"

  {
    echo "paf smoke report"
    echo "utc_time:        $ts"
    echo "batch_job_id:    $JOB_ID"
    echo "run_id:          ${PAF_RUN_ID:-none}"
    echo "git_sha:         $(git -C "$REPO_DIR" rev-parse HEAD 2> /dev/null || echo unknown)"
    echo "emc2_version:    $(Rscript -e 'cat(as.character(packageVersion("EMC2")))')"
    echo "r_version:       $(Rscript -e 'cat(R.version.string)')"
    echo "nproc:           $(nproc)"
    echo "tests_exit_code: $test_rc"
    echo "scope_probe:     $probe_status"
    echo
    echo "--- test summary (last 40 lines) ---"
    tail -n 40 "$test_out"
  } > "$report"

  aws s3 cp "$report" "s3://$BUCKET/results/smoke/${ts}_${JOB_ID}.txt" --only-show-errors
  echo ">>> Report: s3://$BUCKET/results/smoke/${ts}_${JOB_ID}.txt"

  [ "$test_rc" -eq 0 ] || return "$test_rc"
  return "$probe_rc"
}

run_job() {
  validate_env
  echo ">>> paf job: kind=$PAF_KIND run_id=${PAF_RUN_ID:-none} batch_job=$JOB_ID attempt=${AWS_BATCH_JOB_ATTEMPT:-1} git=${PAF_GIT_SHA:-unknown}"
  echo ">>> bucket=$BUCKET args='${ARGS[*]-}'"

  case "$PAF_KIND" in
    smoke)    run_smoke ;;
    fit)      run_fit_kind ;;
    resume)   run_fit_kind ;;
    recovery) "$REPO_DIR/scripts/run_recovery.sh" "${ARGS[@]}" ;;
    bf)       "$REPO_DIR/scripts/run_bf.sh" "${ARGS[@]}" ;;
    ppc)      "$REPO_DIR/scripts/run_ppc.sh" "${ARGS[@]}" ;;
  esac
}

# --- logging, signals and the exit trap --------------------------------------
: > "$LOG_FILE"
exec 3>&1 4>&2                       # keep the real stdout/stderr for after the tee drains
exec > >(tee -a "$LOG_FILE") 2>&1
TEE_PID=$!
CHILD_PID=""

upload_log() {
  command -v aws > /dev/null 2>&1 || return 0
  aws s3 cp "$LOG_FILE" "s3://$BUCKET/results/logs/${JOB_ID}.log" --only-show-errors \
    || echo "WARN: log upload to s3://$BUCKET/results/logs/${JOB_ID}.log failed" >&2
}

on_exit() {
  local rc=$?
  trap - EXIT
  exec >&- 2>&-                      # close the pipe so tee flushes and exits
  wait "$TEE_PID" 2> /dev/null || true
  exec 1>&3 2>&4
  upload_log
  exit "$rc"
}
trap on_exit EXIT

on_signal() {
  echo "batch_entrypoint: received signal $1, stopping the job" >&2
  if [ -n "$CHILD_PID" ]; then
    kill -TERM -- "-$CHILD_PID" 2> /dev/null || true
    wait "$CHILD_PID" 2> /dev/null || true
  fi
  exit $((128 + $1))
}
trap 'on_signal 15' TERM
trap 'on_signal 2' INT

# Background + wait so a signal is handled immediately, not after the child ends.
# The subshell drops the inherited traps: only this (main) shell may run on_exit.
{ trap - EXIT TERM INT; run_job; } &
CHILD_PID=$!
wait "$CHILD_PID"
