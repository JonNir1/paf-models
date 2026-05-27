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
#'     Rscript R/fit/fit_extend_cloud.R 260421_model1.rds
#'
#' Optional overrides (useful for smoke tests - default to fit_config.R globals):
#'   --max-tries N    Override MAX_TRIES   (e.g. --max-tries 3)
#'   --step-size N    Override STEP_SIZE   (e.g. --step-size 5)
#'   --save-every N   Override SAVE_EVERY  (e.g. --save-every 1)
#'   --suffix STR     Append STR to output .rds and log filenames
#'                    (e.g. --suffix _smoke_test)
#'
#' Smoke-test example (checkpoint every try, 3 tries of 5 iterations):
#'   CP_CMD="aws s3 cp" DEST_PREFIX="s3://my-bucket/results" \
#'     Rscript R/fit/fit_extend_cloud.R 260421_model1.rds \
#'       --max-tries 3 --step-size 5 --save-every 1 --suffix _smoke_test
#'
#' The hook is a no-op if CP_CMD or DEST_PREFIX are unset, so the script is
#' also safe to run locally for testing (outputs go to outputs/models/ only).
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")

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
       "Example: Rscript R/fit/fit_extend_cloud.R 260421_model1.rds\n",
       "Smoke:   Rscript R/fit/fit_extend_cloud.R 260421_model1.rds --max-tries 3 --step-size 5")
}

rds_filename <- args[[1]]

# Parse optional overrides; NULL means "use fit_config.R global"
# parse_int_arg / parse_str_arg are defined in R/utils.R
max_tries_override  <- parse_int_arg(args, "--max-tries")
step_size_override  <- parse_int_arg(args, "--step-size")
save_every_override <- parse_int_arg(args, "--save-every")
suffix_override     <- parse_str_arg(args, "--suffix")

# Inject suffix into log filename so smoke-test logs are distinguishable
model_log <- if (!is.null(suffix_override)) {
  base <- tools::file_path_sans_ext(model_log_path(rds_filename))
  paste0(base, suffix_override, ".txt")
} else {
  model_log_path(rds_filename)
}

log_msg(
  sprintf("===== CLOUD EXTEND: %s =====", rds_filename),
  model_log, console_print = TRUE
)
if (!is.null(max_tries_override))
  log_msg(sprintf("Override: --max-tries %d",   max_tries_override),  model_log, console_print = TRUE)
if (!is.null(step_size_override))
  log_msg(sprintf("Override: --step-size %d",   step_size_override),  model_log, console_print = TRUE)
if (!is.null(save_every_override))
  log_msg(sprintf("Override: --save-every %d",  save_every_override), model_log, console_print = TRUE)
if (!is.null(suffix_override))
  log_msg(sprintf("Override: --suffix %s",       suffix_override),     model_log, console_print = TRUE)

result <- tryCatch({
  extend_model(
    rds_filename   = rds_filename,
    log_file       = model_log,
    max_tries      = if (!is.null(max_tries_override))  max_tries_override  else MAX_TRIES,
    step_size      = if (!is.null(step_size_override))  step_size_override  else STEP_SIZE,
    save_every     = if (!is.null(save_every_override)) save_every_override else SAVE_EVERY,
    name_suffix    = if (!is.null(suffix_override))     suffix_override     else "",
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
