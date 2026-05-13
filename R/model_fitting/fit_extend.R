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
source(file.path(CODE_DIR, "model_fitting", "helpers", "model.R"))

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
#' @param min_num_samples Minimum total iterations after extension
#' @param max_tries Maximum extension attempts before bailing without full convergence
#' @param step_size Iterations added per try
#' @param max_rhat_mu,min_ess_mu Thresholds for $mu block
#' @param max_rhat_alpha,min_ess_alpha Thresholds for $alpha block
#' @param save_every NULL (default) or a positive integer. If set, the model is
#'        saved after every `save_every` tries as an intermediate checkpoint, in
#'        addition to the always-executed final save. Useful on spot/preemptible
#'        cloud instances where the process can be killed mid-fit. Must satisfy
#'        `save_every <= max_tries` (otherwise no intermediate save would ever
#'        be written) - this is validated upfront before any heavy computation.
#' @param post_save_hook NULL (default) or a function with signature
#'        `function(rds_path, log_path)`. Called immediately after every save
#'        (both intermediate checkpoints and the final save). Both file paths
#'        are passed so the hook can sync both to durable storage (e.g. S3 or
#'        GCS). Example: `function(rds, log) for (f in c(rds, log))
#'        system(paste("aws s3 cp", f, "s3://my-bucket/results/"))`.
#'        The hook runs synchronously - keep it fast or fire-and-forget the
#'        upload yourself.
#' @return A list with the extended model, save path, final diagnostics, and runtime
extend_model <- function(rds_filename,
                         log_file,
                         models_dir       = MODELS_DIR,
                         min_num_samples  = MIN_NUM_SAMPLES,
                         max_tries        = MAX_TRIES,
                         step_size        = STEP_SIZE,
                         max_rhat_mu      = MAX_RHAT_MU,
                         min_ess_mu       = MIN_ESS_MU,
                         max_rhat_alpha   = MAX_RHAT_ALPHA,
                         min_ess_alpha    = MIN_ESS_ALPHA,
                         save_every       = NULL,
                         post_save_hook   = NULL) {
  start_time <- Sys.time()

  # Validate inputs BEFORE any heavy work so users learn about misconfigs
  # within milliseconds, not hours into an MCMC fit.
  if (!is.null(save_every)) {
    if (!is.numeric(save_every) || length(save_every) != 1 ||
        save_every < 1 || save_every != round(save_every)) {
      stop("save_every must be a positive integer or NULL.")
    }
    if (save_every > max_tries) {
      stop(sprintf(
        "save_every (%d) > max_tries (%d): no intermediate checkpoint would ever be written. Set save_every <= max_tries.",
        save_every, max_tries
      ))
    }
  }
  if (!is.null(post_save_hook) && !is.function(post_save_hook)) {
    stop("post_save_hook must be a function or NULL.")
  }

  # Truncate any prior content - each invocation starts a fresh log
  cat("", file = log_file, append = FALSE)

  # --- Load ---
  full_path <- file.path(models_dir, rds_filename)
  log_msg(sprintf("Loading model from %s", full_path), log_file, console_print = TRUE)
  model <- readRDS(full_path)

  # n_chains is fixed by the emc object (list-of-chains at top level; cannot be
  # changed after make_emc()). Derive parallelism from machine at runtime.
  n_chains  <- length(model)
  core_args <- get_core_args(n_chains)
  log_msg(
    sprintf("Core config: n_chains=%d, cores_for_chains=%d, cores_per_chain=%d (machine has %d cores)",
            n_chains, core_args$cores_for_chains, core_args$cores_per_chain,
            parallel::detectCores()),
    log_file, console_print = TRUE
  )

  # Strip the leading date prefix and any pre-existing _extended suffix chain
  # so the save name is idempotent across resume cycles. Examples:
  #   260421_model1.rds                    -> model1
  #   260512_model1_extended.rds           -> model1
  #   260513_model1_extended_extended.rds  -> model1   (legacy double; also healed)
  orig_model_name <- sub("^[0-9]{6}_",     "", tools::file_path_sans_ext(rds_filename))
  orig_model_name <- sub("(_extended)+$",  "", orig_model_name)
  ext_model_name  <- paste0(orig_model_name, "_extended")

  # Pin the date prefix at function entry so all intermediate + final saves
  # land in the SAME file even if the run crosses midnight. Without this, a
  # long fit produces multiple stale .rds files (one per calendar day).
  run_date <- format(Sys.Date(), "%y%m%d")

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
    log_msg(sprintf("Try %d/%d: adding %d iterations (cores_for_chains=%d, cores_per_chain=%d)...",
                    try_idx, max_tries, step_size,
                    core_args$cores_for_chains, core_args$cores_per_chain),
            log_file, console_print = TRUE)

    # Add exactly `step_size` iterations per outer-loop try, then evaluate
    # our asymmetric per-block convergence ourselves below.
    #
    # EMC2 internals (verified against EMC2 v3.3.0 source):
    #   - In run_emc, for stage=="sample" the effective target is
    #     `iter_target = stop_criteria$iter + current_chain_length`.
    #     So stop_criteria$iter is an ADDITIVE delta, not an absolute total.
    #   - check_progress sets done = (es & iter & gd & adapted) | (trys & iter).
    #     BOTH branches require iter_done. max_tries alone does NOT terminate
    #     the loop - iter_done must be reachable.
    # Setting stop_criteria$iter = step_size makes the target exactly
    # current+step_size, so iter_done flips to TRUE after one pass.
    # max_gr = 1.5 and min_es = 1 are trivially met (Rhat is always < ~1.2
    # for sampled models; ESS is always > 1) so es_done and gd_done are TRUE.
    # max_tries = 1 is a redundant safety bound.
    model <- run_emc(
      model,
      stage            = "sample",
      stop_criteria    = list(iter = step_size, max_gr = 1.5, min_es = 1),
      max_tries        = 1,
      step_size        = step_size,
      cores_for_chains = core_args$cores_for_chains,
      cores_per_chain  = core_args$cores_per_chain
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

    # Intermediate checkpoint, if requested. Protects against spot-instance
    # preemption: if the instance dies after this save, on resume we lose at
    # most `save_every * step_size` iterations of work.
    if (!is.null(save_every) && (try_idx %% save_every == 0L)) {
      saved_path <- save_model(model, ext_model_name, models_dir,
                               date_prefix = run_date)
      log_msg(sprintf("Checkpoint after try %d: %s", try_idx, saved_path),
              log_file, console_print = TRUE)
      if (!is.null(post_save_hook)) post_save_hook(saved_path, log_file)
    }

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

  # --- Final save (always runs, regardless of save_every) ---
  saved_path <- save_model(model, ext_model_name, models_dir,
                           date_prefix = run_date)
  log_msg(
    paste("Saved extended model to:", saved_path),
    log_file,
    console_print = TRUE
  )
  if (!is.null(post_save_hook)) post_save_hook(saved_path, log_file)

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

  log_msg(
    sprintf("===== SINGLE-MODEL EXTEND: %s =====", rds_filename),
    model_log,
    console_print = TRUE
  )

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
  log_msg(
    sprintf("Models queued: %s", paste(model_files, collapse = ", ")),
    batch_log,
    console_print = TRUE
  )

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
