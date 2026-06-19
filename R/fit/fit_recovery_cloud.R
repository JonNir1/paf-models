#' =============================================================================
#' Parameter Recovery - Cloud Runner (step 2.5)
#'
#' Runs one recovery simulation for one model on a cloud VM. For each call:
#'   1. Load a previously-extended model (.rds from fit_extend/)
#'   2. Extract group-level posterior (mu, Sigma) via extract_group_params()
#'   3. Draw fresh subject parameters + simulate data via simulate_recovery_data()
#'   4. Refit the same model from scratch on the simulated data (same priors)
#'   5. Extend until relaxed convergence criteria are met
#'   6. Save recovered model + true subject params; sync to S3/GCS
#'
#' Replicates Strickland et al. (2026) Supplementary parameter recovery protocol.
#'
#' The recovery pipeline (steps 2-5 + save) is exposed as the function
#' run_recovery_fit() so smoke tests can drive it directly with a subsetted
#' template_data (avoiding the ~15-minute make_data() pass on the full 14.5k
#' dataset). The script below is the CLI wrapper around that function.
#'
#' Usage (called by scripts/run_recovery.sh, or directly for local testing):
#'   Rscript R/fit/fit_recovery_cloud.R <extended_rds> <sim_index>
#'   e.g.: Rscript R/fit/fit_recovery_cloud.R 260525_model1_extended.rds 1
#'
#' Optional overrides (default to fit_config.R globals):
#'   --fit-samples N  Override RECOVERY_FIT_SAMPLES for the initial fit
#'   --max-tries N    Override MAX_TRIES for the post-fit extension loop
#'   --step-size N    Override STEP_SIZE for the extension loop
#'   --save-every N   Override SAVE_EVERY
#'   --suffix STR     Append STR to output filenames (e.g. _smoke)
#'
#' Cloud sync: reads CP_CMD and DEST_PREFIX from the environment (set by
#' scripts/run_recovery.sh). No-op if either is unset (safe for local use).
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/recovery.R")


# =============================================================================
#' Recovery pipeline (callable; no CLI / no I/O of inputs).
#'
#' Given an already-loaded fitted model and template data, runs the full
#' recovery cycle: extract -> simulate -> save true_alpha -> source modelN.R ->
#' build_model on simulated data -> fit -> save checkpoint -> extend.
#'
#' Inputs and outputs (log file, dirs) are explicit parameters so this is
#' equally usable from the CLI runner and from smoke tests.
#'
#' @param extended_model       Loaded EMC2 model object (output of fit_extend).
#' @param template_data        Filtered design-matrix data frame (trial structure
#'                              for make_data). May be a subset for fast smoke tests.
#' @param model_script_path    Absolute path to the model definition script
#'                              (e.g. .../R/fit/mymodel.R). Must define build_model().
#' @param recovery_name        Base name for output .rds files (without date prefix).
#' @param log_file             Path to write timestamped progress lines.
#' @param out_dir              Directory for recovered model + true_alpha .rds files.
#' @param sim_seed             RNG seed for simulate_recovery_data.
#' @param convergence_criteria Recovery convergence target (relaxed). Default:
#'                              default_convergence_criteria("recovery").
#' @param max_tries            Max sampling batches to add.
#' @param batch_size           Sample iters added per try.
#' @param save_every           Checkpoint frequency (in tries).
#' @param post_save_hook       Optional function(rds_path, log_path) called
#'                              after each checkpoint (e.g. .cloud_hook for S3).
#' @param init_stop_criteria   Optional stop_criteria for the warm-up fit (e.g.
#'                              list(max_gd = Inf) for smoke tests). NULL in prod.
#' @return character "COMPLETE" on success; on failure, the error is re-thrown
#'   so the CLI's tryCatch can log it. Side effects: writes true_alpha and the
#'   recovered model .rds to out_dir.
run_recovery_fit <- function(extended_model, template_data, model_script_path,
                             recovery_name, log_file, out_dir, sim_seed,
                             convergence_criteria = default_convergence_criteria("recovery"),
                             max_tries          = MAX_TRIES_RECOVERY,
                             batch_size         = STEP_SIZE_RECOVERY,
                             save_every         = SAVE_EVERY,
                             post_save_hook     = NULL,
                             init_stop_criteria = NULL) {

  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  run_date <- format(Sys.Date(), "%y%m%d")
  if (is.null(post_save_hook)) post_save_hook <- function(...) invisible(NULL)

  log_msg(sprintf("Template data: %d trials, %d subjects",
                  nrow(template_data), dplyr::n_distinct(template_data$subjects)),
          log_file, console_print = TRUE)

  # --- 1. Extract group-level parameters ---
  log_msg("Extracting group parameters (mu, Sigma)...", log_file, console_print = TRUE)
  group_params <- extract_group_params(extended_model)
  log_msg(sprintf("  mu: %d parameters", length(group_params$mu)), log_file, console_print = TRUE)
  log_msg(sprintf("  Sigma: %dx%d matrix",
                  nrow(group_params$Sigma), ncol(group_params$Sigma)),
          log_file, console_print = TRUE)

  # --- 2. Simulate recovery dataset ---
  log_msg(sprintf("Simulating recovery data (seed = %d)...", sim_seed),
          log_file, console_print = TRUE)
  sim_result <- simulate_recovery_data(extended_model, group_params,
                                       template_data, seed = sim_seed)
  sim_data   <- sim_result$data
  true_alpha <- sim_result$subject_pars
  log_msg(sprintf("  Simulated: %d trials, %d subjects",
                  nrow(sim_data), dplyr::n_distinct(sim_data$subjects)),
          log_file, console_print = TRUE)

  # --- 3. Save true alpha alongside the recovered model ---
  true_alpha_path <- file.path(out_dir,
                               sprintf("%s_%s_true_alpha.rds", run_date, recovery_name))
  saveRDS(true_alpha, true_alpha_path)
  log_msg(sprintf("Saved true subject params: %s", true_alpha_path),
          log_file, console_print = TRUE)
  post_save_hook(true_alpha_path, log_file)

  # --- 4. Source model script to get build_model() ---
  if (!file.exists(model_script_path)) {
    stop(sprintf("Model script not found: %s", model_script_path))
  }
  log_msg(sprintf("Sourcing model script: %s", model_script_path),
          log_file, console_print = TRUE)
  source(model_script_path)   # defines build_model() and MODEL_NAME

  # --- 5. Build fresh model object on simulated data ---
  log_msg("Building fresh model on simulated data...", log_file, console_print = TRUE)
  fresh_model <- build_model(sim_data, n_chains = N_CHAINS)

  # --- 6. Fit to (relaxed) convergence via the unified core ---
  # fit_to_convergence() warms up the fresh model (preburn -> burn -> adapt ->
  # an initial sample batch) then samples to the recovery convergence_criteria.
  # init_stop_criteria is NULL in production; smoke tests pass loose criteria
  # (e.g. list(max_gd = Inf)) so the warm-up phases exit quickly on tiny chains.
  save_path <- file.path(out_dir, sprintf("%s_%s.rds", run_date, recovery_name))
  log_msg("Fitting recovered model to relaxed convergence...", log_file, console_print = TRUE)
  fit_to_convergence(
    fresh_model,
    convergence_criteria = convergence_criteria,
    max_tries            = max_tries,
    batch_size           = batch_size,
    save_every           = save_every,
    save_path            = save_path,
    post_save_hook       = post_save_hook,
    log_file             = log_file,
    init_stop_criteria   = init_stop_criteria,
    append_log           = TRUE
  )

  "COMPLETE"
}


# =============================================================================
# CLI wrapper.  Triggers only when run with CLI args; tests can `source()` this
# file to access run_recovery_fit() without launching a fit.
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) == 0L) {
  # File was sourced (e.g. from a smoke test) -- just expose run_recovery_fit().
} else if (length(args) < 2L) {
  stop(
    "Usage: Rscript fit_recovery_cloud.R <extended_rds> <sim_index> [options]\n",
    "Example: Rscript R/fit/fit_recovery_cloud.R 260525_model1_extended.rds 1\n",
    "Smoke:   Rscript R/fit/fit_recovery_cloud.R 260525_model1_extended.rds 1 ",
    "--fit-samples 5 --max-tries 1 --step-size 5 --save-every 1 --suffix _smoke"
  )
} else {

  RNGkind(RNG_KIND)
  set.seed(RNG_SEED)

  # ---- Cloud sync hook (only meaningful in the CLI path) ----
  .cloud_hook <- function(rds_path, log_path) {
    cp_cmd      <- Sys.getenv("CP_CMD",      unset = "")
    dest_prefix <- Sys.getenv("DEST_PREFIX", unset = "")
    if (!nzchar(cp_cmd) || !nzchar(dest_prefix)) return(invisible(NULL))
    for (f in c(rds_path, log_path))
      system(paste(cp_cmd, shQuote(f), paste0(dest_prefix, "/")), wait = TRUE)
  }

  extended_rds <- args[[1]]
  sim_index    <- as.integer(args[[2]])
  if (is.na(sim_index) || sim_index < 1L) {
    stop(sprintf("Invalid sim_index '%s': must be a positive integer.", args[[2]]))
  }

  max_tries_override   <- parse_int_arg(args, "--max-tries")
  step_size_override   <- parse_int_arg(args, "--step-size")
  save_every_override  <- parse_int_arg(args, "--save-every")
  fit_samples_override <- parse_int_arg(args, "--fit-samples")
  suffix_override      <- parse_str_arg(args, "--suffix")
  suffix <- if (!is.null(suffix_override)) suffix_override else ""

  # Derive model name from rds filename: strip date prefix + _extended suffix
  orig_name     <- sub("^[0-9]{6}_", "", tools::file_path_sans_ext(extended_rds))
  orig_name     <- sub("(_extended)+$", "", orig_name)
  recovery_name <- sprintf("%s_recovery_sim%d%s", orig_name, sim_index, suffix)

  if (!dir.exists(MODELS_RECOVERY_DIR)) dir.create(MODELS_RECOVERY_DIR, recursive = TRUE)

  log_file <- file.path(MODELS_RECOVERY_DIR,
                        sprintf("log_recovery_%s_sim%d%s.txt",
                                orig_name, sim_index, suffix))
  cat("", file = log_file, append = FALSE)

  log_msg(sprintf("===== RECOVERY: %s  sim=%d =====", extended_rds, sim_index),
          log_file, console_print = TRUE)
  log_msg(sprintf("Output name: %s", recovery_name), log_file, console_print = TRUE)
  for (override in list(
         list("--fit-samples", fit_samples_override),
         list("--max-tries",   max_tries_override),
         list("--step-size",   step_size_override),
         list("--save-every",  save_every_override),
         list("--suffix",      suffix_override))) {
    if (!is.null(override[[2]]))
      log_msg(sprintf("Override: %s %s", override[[1]], override[[2]]),
              log_file, console_print = TRUE)
  }

  result <- tryCatch({
    ext_path <- file.path(MODELS_FIT_DIR, extended_rds)
    log_msg(sprintf("Loading source (converged) model from: %s", ext_path),
            log_file, console_print = TRUE)
    extended_model <- readRDS(ext_path)

    log_msg(sprintf("Loading template data from raw CSVs in: %s", DATA_DIR),
            log_file, console_print = TRUE)
    template_data <- load_data(min_rt               = MIN_SACCADE_CUTOFF,
                               max_rt               = MAX_SACCADE_CUTOFF,
                               allow_target_repeats = ALLOW_TARGET_REPEAT)

    model_script <- file.path(Sys.getenv("PAF_REPO_ROOT", getwd()),
                              "R", "fit", paste0(orig_name, ".R"))

    # Recovery convergence target (relaxed); --fit-samples overrides the floor.
    recovery_criteria <- default_convergence_criteria("recovery")
    if (!is.null(fit_samples_override))
      recovery_criteria$num_samples <- fit_samples_override

    run_recovery_fit(
      extended_model    = extended_model,
      template_data     = template_data,
      model_script_path = model_script,
      recovery_name     = recovery_name,
      log_file          = log_file,
      out_dir           = MODELS_RECOVERY_DIR,
      sim_seed          = RECOVERY_BASE_SEED + sim_index,
      convergence_criteria = recovery_criteria,
      max_tries         = if (!is.null(max_tries_override))   max_tries_override   else MAX_TRIES_RECOVERY,
      batch_size        = if (!is.null(step_size_override))   step_size_override   else STEP_SIZE_RECOVERY,
      save_every        = if (!is.null(save_every_override))  save_every_override  else SAVE_EVERY,
      post_save_hook    = .cloud_hook
    )
    "COMPLETE"
  }, error = function(e) {
    log_error(e, log_file,
              context = sprintf("recovery('%s', sim=%d)", extended_rds, sim_index))
    "ERROR"
  })

  log_msg(sprintf("===== %s: %s =====", recovery_name, result),
          log_file, console_print = TRUE)
}
