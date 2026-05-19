#' =============================================================================
#' Extend Model Fitting - Local Runner
#'
#' Extends previously-fit models on a local machine. Runs two models in parallel
#' when the machine has enough cores (>= 2 * N_CHAINS); otherwise falls back to
#' sequential execution. Each model gets its own log file so outputs never
#' interleave. Intermediate checkpoints are saved to `emc2_models/` after every
#' try so a crash loses at most one try's work.
#'
#' Usage:
#'   Rscript R/model_fitting/fit_extend_local.R              # parallel if cores allow
#'   Rscript R/model_fitting/fit_extend_local.R --sequential # force sequential
#'
#' Must run AFTER fit_initial.R. Update `model_files` below to match the actual
#' .rds filenames in emc2_models/ before running.
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
# Configuration
# =============================================================================

## IMPORTANT: update these filenames to match emc2_models/ before running ##
model_files <- c(
  "260421_model1.rds",
  "260409_model2.rds",
  "260424_model4.rds",
  "260412_model5.rds"
)

args           <- commandArgs(trailingOnly = TRUE)
run_sequential <- "--sequential" %in% args

# Maximum models to run simultaneously: limited by available cores.
# On Windows, cores_per_chain = 1, so each model uses exactly N_CHAINS cores.
# On Linux/Mac, cores_per_chain > 1, but we still cap at 2 parallel models to
# avoid memory pressure (each loaded model can be several hundred MB).
max_parallel <- if (run_sequential) 1L else
  min(2L, floor(parallel::detectCores() / N_CHAINS))

batch_log <- file.path(MODELS_DIR, "log_extend_batch.txt")
cat("", file = batch_log, append = FALSE)  # truncate any prior batch log
log_msg("===== LOCAL EXTEND SESSION START =====", batch_log, console_print = TRUE)
log_msg(
  sprintf("Models: %s", paste(model_files, collapse = ", ")),
  batch_log, console_print = TRUE
)
log_msg(
  sprintf("Mode: %s | max_parallel=%d | machine has %d cores",
          if (run_sequential) "sequential (--sequential flag)" else "parallel",
          max_parallel, parallel::detectCores()),
  batch_log, console_print = TRUE
)


# =============================================================================
# Worker function for PSOCK parallel execution
# =============================================================================
# Self-contained: sources all dependencies itself so it runs cleanly in an
# isolated worker R session (PSOCK workers do not inherit parent environment).

.worker_fn <- function(rds_filename, repo_root) {
  setwd(repo_root)
  root_env <- Sys.getenv("PAF_REPO_ROOT", unset = "")
  if (nzchar(root_env)) {
    source(file.path(root_env, "R", "model_fitting", "helpers", "fitting.R"))
  } else {
    source("R/model_fitting/helpers/fitting.R")
  }
  log_file <- model_log_path(rds_filename)
  tryCatch(
    extend_model(rds_filename, log_file = log_file, save_every = 1L),
    error = function(e) {
      if (exists("log_error", mode = "function")) {
        log_error(e, log_file, context = sprintf("extend_model('%s')", rds_filename))
      } else {
        cat(sprintf("[ERROR] %s: %s\n", rds_filename, conditionMessage(e)))
      }
    }
  )
}


# =============================================================================
# Batch runner
# =============================================================================

.run_batch_parallel <- function(batch, repo_root, batch_log) {
  n_workers <- length(batch)
  log_msg(
    sprintf("Launching %d parallel worker(s): %s", n_workers, paste(batch, collapse = ", ")),
    batch_log, console_print = TRUE
  )
  cl <- parallel::makeCluster(n_workers, type = "PSOCK")
  on.exit(parallel::stopCluster(cl), add = TRUE)
  parallel::parLapply(cl, batch, .worker_fn, repo_root = getwd())
  invisible(NULL)
}


# =============================================================================
# Main execution
# =============================================================================

repo_root <- getwd()

if (max_parallel >= 2) {
  # Split model list into batches of max_parallel and run each batch in parallel
  batch_indices <- ceiling(seq_along(model_files) / max_parallel)
  batches       <- split(model_files, batch_indices)

  for (i in seq_along(batches)) {
    batch <- batches[[i]]
    log_msg(sprintf("--- Batch %d/%d ---", i, length(batches)),
            batch_log, console_print = TRUE)
    tryCatch(
      .run_batch_parallel(batch, repo_root, batch_log),
      error = function(e) log_error(e, batch_log,
                                    context = sprintf("batch %d: %s", i,
                                                      paste(batch, collapse = ", ")))
    )
    gc()
    Sys.sleep(5)  # allow socket ports to clear before next batch
  }

} else {
  # Sequential fallback: one model at a time
  for (mf in model_files) {
    model_log <- model_log_path(mf)
    log_msg(sprintf("Extending %s (log: %s)", mf, model_log),
            batch_log, console_print = TRUE)
    log_msg(sprintf("===== EXTEND: %s =====", mf), model_log, console_print = TRUE)

    status <- tryCatch({
      extend_model(mf, log_file = model_log, save_every = 1L)
      "COMPLETE"
    }, error = function(e) {
      log_error(e, model_log, context = sprintf("extend_model('%s')", mf))
      "ERROR"
    })

    log_msg(sprintf("%s: %s", mf, status), batch_log, console_print = TRUE)
    log_msg(sprintf("===== %s: %s =====", mf, status), model_log, console_print = TRUE)
    try(parallel::stopCluster(cl = NULL), silent = TRUE)
    Sys.sleep(5)
    gc()
  }
}

log_msg("===== LOCAL EXTEND SESSION END =====", batch_log, console_print = TRUE)
