#' =============================================================================
#' --- Extend Model Fitting ---
#' Operates on previously-fit models, extending each until $mu and $alpha meet
#' the asymmetric convergence thresholds defined in `R/config.R`. $sigma2 and
#' $correlation are NOT enforced - they are reported descriptively post-fit.
#' Must run AFTER `fit_initial.R` (which fits each model for MIN_NUM_SAMPLES).
#'
#' Modes:
#'   Sequential (default): loops over the hardcoded `model_files` list below.
#'     Each model gets its own detail log under MODELS_DIR/log_extend_<name>.txt
#'     so per-model output is not interleaved.
#'   Single-model (parallel-friendly): pass an .rds filename as a command-line
#'     argument. The script extends that one model only and writes to its own
#'     log file. Multiple instances can run concurrently (e.g. one per cloud
#'     node) without log contention.
#'     Example: Rscript R/model_fitting/fit_extend.R 260421_model1.rds
#' =============================================================================

# Load Core Configurations and Helpers
library(EMC2)

source("R/config.R")
source(file.path(CODE_DIR, "model_fitting", "helpers.R"))

# Setup Global Reproducibility (per-instance; each parallel invocation gets the
# same seed but operates on a different starting model, so results diverge)
RNGkind(RNG_KIND)
set.seed(RNG_SEED)


# =============================================================================
# Core fit-extension function
# =============================================================================

#' Extend a previously-fit EMC2 model until $mu and $alpha converge.
#' Self-contained: takes all config as arguments so it is safe to call in
#' parallel (one process per model on cloud, no shared mutable state).
#'
#' @param rds_filename Filename of the .rds model under `models_dir`
#'        (e.g. "260421_model1.rds")
#' @param log_file Path to this invocation's detail log file
#' @param models_dir Directory containing the .rds and where extended model is saved
#' @param num_cores Cores for MCMC chains (defaults to NUM_CORES)
#' @param min_num_samples Minimum total iterations after extension
#' @param max_tries Maximum extension attempts before bailing without full convergence
#' @param step_size Iterations added per try
#' @param max_rhat_mu,min_ess_mu Thresholds for $mu block
#' @param max_rhat_alpha,min_ess_alpha Thresholds for $alpha block
#' @return A list with the extended model, save path, final diagnostics, and runtime
extend_model <- function(rds_filename,
                         log_file,
                         models_dir       = MODELS_DIR,
                         num_cores        = NUM_CORES,
                         min_num_samples  = MIN_NUM_SAMPLES,
                         max_tries        = MAX_TRIES,
                         step_size        = STEP_SIZE,
                         max_rhat_mu      = MAX_RHAT_MU,
                         min_ess_mu       = MIN_ESS_MU,
                         max_rhat_alpha   = MAX_RHAT_ALPHA,
                         min_ess_alpha    = MIN_ESS_ALPHA) {
  start_time <- Sys.time()

  # Truncate any prior content - each invocation starts a fresh log
  cat("", file = log_file, append = FALSE)

  # --- Load ---
  full_path <- file.path(models_dir, rds_filename)
  log_msg(sprintf("Loading model from %s", full_path), log_file, console_print = TRUE)
  model <- readRDS(full_path)
  orig_model_name <- sub("^[0-9]{6}_", "", tools::file_path_sans_ext(rds_filename))
  ext_model_name  <- paste0(orig_model_name, "_extended")

  log_msg(sprintf(
    "Extension targets: mu(Rhat<%.2f, ESS>%d) | alpha(Rhat<%.2f, ESS>%d) | step_size=%d | max_tries=%d",
    max_rhat_mu, min_ess_mu, max_rhat_alpha, min_ess_alpha, step_size, max_tries
  ), log_file, console_print = TRUE)

  # --- Custom asymmetric extension loop ---
  # EMC2's built-in stop_criteria treats all parameters uniformly, so we cannot
  # use it to enforce different thresholds on $mu vs $alpha. Instead we add
  # `step_size` iterations per try via run_emc(max_tries=1, step_size=step_size)
  # and evaluate block-specific convergence ourselves between tries.
  converged <- FALSE
  cv <- NULL
  try_idx <- 0L
  for (try_idx in seq_len(max_tries)) {
    log_msg(sprintf("Try %d/%d: adding %d iterations on %d cores...",
                    try_idx, max_tries, step_size, num_cores),
            log_file, console_print = TRUE)

    # Bypass EMC2's built-in convergence-driven sampling: set stop_criteria
    # values so that max_gr and min_es are trivially met (1.5 is above any
    # realistic Rhat; 1 is below any realistic ESS), while iter is reachable
    # but well above any total we'd hit (1e9). With max_tries = 1 and these
    # finite values, EMC2 adds exactly `step_size` iterations and returns.
    # We then evaluate our asymmetric per-block convergence ourselves below.
    # (Earlier attempt used Inf and max_gr<1.0, which hung run_emc - apparently
    # those values break its internal bounded loop.)
    model <- run_emc(
      model,
      stage             = "sample",
      stop_criteria     = list(iter = 1e9, max_gr = 1.5, min_es = 1),
      max_tries         = 1,
      step_size         = step_size,
      cores_for_chains  = num_cores
    )

    cv <- check_block_convergence(
      model,
      max_rhat_mu, min_ess_mu,
      max_rhat_alpha, min_ess_alpha
    )
    log_msg(sprintf(
      "  mu:    Rhat=%.4f (<%.2f) | ESS=%.0f (>%d)  [%s]",
      cv$mu_max_rhat, max_rhat_mu, cv$mu_min_ess, min_ess_mu,
      ifelse(cv$mu_converged, "OK", "WAIT")
    ), log_file, console_print = TRUE)
    log_msg(sprintf(
      "  alpha: Rhat=%.4f (<%.2f) | ESS=%.0f (>%d)  [%s]",
      cv$alpha_max_rhat, max_rhat_alpha, cv$alpha_min_ess, min_ess_alpha,
      ifelse(cv$alpha_converged, "OK", "WAIT")
    ), log_file, console_print = TRUE)

    if (cv$converged) {
      converged <- TRUE
      log_msg(sprintf("Converged after %d tries.", try_idx),
              log_file, console_print = TRUE)
      break
    }
  }

  if (!converged) {
    log_msg(sprintf("Max tries (%d) exhausted without full convergence on $mu and $alpha.",
                    max_tries),
            log_file, console_print = TRUE)
  }

  # --- Save ---
  saved_path <- save_model(model, ext_model_name, models_dir)
  log_msg(
    paste("Saved extended model to:", saved_path),
    log_file,
    console_print = TRUE
  )

  duration_min <- as.numeric(difftime(Sys.time(), start_time, units = "mins"))
  log_msg(
    sprintf("Total runtime: %.2f minutes", duration_min),
    log_file,
    console_print = TRUE
  )

  return(list(
    model         = model,
    saved_path    = saved_path,
    diagnostics   = cv,
    n_tries       = try_idx,
    converged     = converged,
    duration_min  = duration_min
  ))
}


#' Build a per-model log file path under `MODELS_DIR`.
#' Each fit_extend invocation writes to its own log to avoid interleaving when
#' running multiple instances in parallel (one process per model).
model_log_path <- function(rds_filename, models_dir = MODELS_DIR) {
  base <- tools::file_path_sans_ext(rds_filename)
  file.path(models_dir, paste0("log_extend_", base, ".txt"))
}


# =============================================================================
# Main script logic
# =============================================================================
# Guard so that source()-ing this file only loads function definitions.
# Main logic runs only when the file is invoked directly via Rscript.
if (sys.nframe() == 0L) {

args <- commandArgs(trailingOnly = TRUE)

if (length(args) >= 1) {
  # ---------- Single-model mode (parallel-friendly) ----------
  rds_filename <- args[[1]]
  model_log    <- model_log_path(rds_filename)

  log_msg(sprintf("===== SINGLE-MODEL EXTEND: %s =====", rds_filename),
          model_log, console_print = TRUE)
  log_config_variables(CONFIG_FILE, model_log)

  result <- tryCatch({
    extend_model(rds_filename, log_file = model_log)
    "COMPLETE"
  }, error = function(e) {
    log_error(e, model_log, context = sprintf("extend_model('%s')", rds_filename))
    "ERROR"
  })

  log_msg(sprintf("===== %s: %s =====", rds_filename, result),
          model_log, console_print = TRUE)

} else {
  # ---------- Batch mode (sequential loop) ----------
  ## IMPORTANT: edit this list to match models you want to extend ##
  model_files <- c(
    "260421_model1.rds",
    "260409_model2.rds",
    "260424_model4.rds",
    "260412_model5.rds"
  )

  batch_log <- file.path(MODELS_DIR, "log_extend_batch.txt")
  cat("", file = batch_log, append = FALSE)  # truncate prior batch log
  log_msg("===== BATCH EXTEND SESSION START =====", batch_log, console_print = TRUE)
  log_config_variables(CONFIG_FILE, batch_log)
  log_msg(sprintf("Models queued: %s", paste(model_files, collapse = ", ")),
          batch_log, console_print = TRUE)

  for (mf in model_files) {
    model_log <- model_log_path(mf)
    log_msg(sprintf("Dispatching %s (detail log: %s)", mf, model_log),
            batch_log, console_print = TRUE)
    log_msg(sprintf("===== EXTEND: %s =====", mf), model_log, console_print = TRUE)

    status <- tryCatch({
      extend_model(mf, log_file = model_log)
      "COMPLETE"
    }, error = function(e) {
      log_error(e, model_log, context = sprintf("extend_model('%s')", mf))
      "ERROR"
    })

    log_msg(sprintf("%s: %s", mf, status), batch_log, console_print = TRUE)
    log_msg(sprintf("===== %s: %s =====", mf, status),
            model_log, console_print = TRUE)

    # Free resources between models so the next fit gets a clean slate
    try(parallel::stopCluster(cl = NULL), silent = TRUE)
    Sys.sleep(5)  # avoid TIME_WAIT on socket ports
    gc()
  }

  log_msg("===== BATCH EXTEND SESSION END =====", batch_log, console_print = TRUE)
}

}  # end if (sys.nframe() == 0L)
