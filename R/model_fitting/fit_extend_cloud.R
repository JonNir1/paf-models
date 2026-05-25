#' =============================================================================
#' Extend Model Fitting - Cloud Runner (single-model mode)
#'
#' Extends one previously-fit model on a cloud VM. Designed for parallel
#' execution: one process per machine, each handling a single model. After
#' every try the model and log are synced to durable storage via a hook that
#' reads CP_CMD and DEST_PREFIX from the environment (set by cloud_setup.sh).
#'
#' Usage (called by cloud_setup.sh do_run, not directly):
#'   CP_CMD="aws s3 cp" DEST_PREFIX="s3://my-bucket/results" \
#'     Rscript R/model_fitting/fit_extend_cloud.R 260421_model1.rds
#'
#' Optional overrides (useful for smoke tests - default to config.R globals):
#'   --max-tries N   Override MAX_TRIES   (e.g. --max-tries 3)
#'   --step-size N   Override STEP_SIZE   (e.g. --step-size 5)
#'   --save-every N  Override SAVE_EVERY  (e.g. --save-every 1)
#'
#' Smoke-test example (checkpoint every try, 3 tries of 5 iterations):
#'   CP_CMD="aws s3 cp" DEST_PREFIX="s3://my-bucket/results" \
#'     Rscript R/model_fitting/fit_extend_cloud.R 260421_model1.rds \
#'       --max-tries 3 --step-size 5 --save-every 1
#'
#' The hook is a no-op if CP_CMD or DEST_PREFIX are unset, so the script is
#' also safe to run locally for testing (outputs go to emc2_models/ only).
#' =============================================================================

library(EMC2)

local({
  root <- Sys.getenv("PAF_REPO_ROOT", unset = "")
  if (nzchar(root)) source(file.path(root, "R", "model_fitting", "helpers", "fitting.R"))
  else              source("R/model_fitting/helpers/fitting.R")
})

RNGkind(RNG_KIND)
set.seed(RNG_SEED)


# =============================================================================
#  Cloud sync hook: reads CP_CMD + DEST_PREFIX from the environment at call
#  time (not definition time) so values set by cloud_setup.sh are picked up
#  correctly. No-op when either variable is unset.
# =============================================================================

.cloud_hook <- function(rds_path, log_path) {
  cp_cmd      <- Sys.getenv("CP_CMD",      unset = "")
  dest_prefix <- Sys.getenv("DEST_PREFIX", unset = "")
  if (!nzchar(cp_cmd) || !nzchar(dest_prefix)) return(invisible(NULL))
  for (f in c(rds_path, log_path))
    system(paste(cp_cmd, shQuote(f), paste0(dest_prefix, "/")), wait = TRUE)
}


# =============================================================================
# Main execution
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 1) {
  stop("Usage: Rscript fit_extend_cloud.R <rds_filename> [--max-tries N] [--step-size N]\n",
       "Example: Rscript R/model_fitting/fit_extend_cloud.R 260421_model1.rds\n",
       "Smoke:   Rscript R/model_fitting/fit_extend_cloud.R 260421_model1.rds --max-tries 3 --step-size 5")
}

rds_filename <- args[[1]]

# Parse optional integer overrides; NULL means "use config.R global"
.parse_int_arg <- function(args, flag) {
  idx <- which(args == flag)
  if (length(idx) > 0L && idx[[1L]] < length(args)) as.integer(args[[idx[[1L]] + 1L]]) else NULL
}
max_tries_override  <- .parse_int_arg(args, "--max-tries")
step_size_override  <- .parse_int_arg(args, "--step-size")
save_every_override <- .parse_int_arg(args, "--save-every")

model_log <- model_log_path(rds_filename)

log_msg(
  sprintf("===== CLOUD EXTEND: %s =====", rds_filename),
  model_log, console_print = TRUE
)
if (!is.null(max_tries_override))
  log_msg(sprintf("Override: --max-tries %d",  max_tries_override),  model_log, console_print = TRUE)
if (!is.null(step_size_override))
  log_msg(sprintf("Override: --step-size %d",  step_size_override),  model_log, console_print = TRUE)
if (!is.null(save_every_override))
  log_msg(sprintf("Override: --save-every %d", save_every_override), model_log, console_print = TRUE)

result <- tryCatch({
  extend_model(
    rds_filename   = rds_filename,
    log_file       = model_log,
    max_tries      = if (!is.null(max_tries_override))  max_tries_override  else MAX_TRIES,
    step_size      = if (!is.null(step_size_override))  step_size_override  else STEP_SIZE,
    save_every     = if (!is.null(save_every_override)) save_every_override else SAVE_EVERY,
    post_save_hook = .cloud_hook
  )
  "COMPLETE"
}, error = function(e) {
  log_error(e, model_log, context = sprintf("extend_model('%s')", rds_filename))
  "ERROR"
})

log_msg(
  sprintf("===== %s: %s =====", rds_filename, result),
  model_log, console_print = TRUE
)
