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
  stop("Usage: Rscript fit_extend_cloud.R <rds_filename>\n",
       "Example: Rscript R/model_fitting/fit_extend_cloud.R 260421_model1.rds")
}

rds_filename <- args[[1]]
model_log    <- model_log_path(rds_filename)

log_msg(
  sprintf("===== CLOUD EXTEND: %s =====", rds_filename),
  model_log, console_print = TRUE
)

result <- tryCatch({
  extend_model(
    rds_filename   = rds_filename,
    log_file       = model_log,
    save_every     = 1L,
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
