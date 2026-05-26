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
#' Usage (called by cloud_setup.sh do_recovery, or directly for local testing):
#'   Rscript R/model_fitting/fit_recovery_cloud.R <extended_rds> <sim_index>
#'   e.g.: Rscript R/model_fitting/fit_recovery_cloud.R 260525_model1_extended.rds 1
#'
#' Optional overrides (default to config.R globals):
#'   --max-tries N    Override MAX_TRIES for the post-fit extension loop
#'   --step-size N    Override STEP_SIZE for the extension loop
#'   --save-every N   Override SAVE_EVERY
#'   --suffix STR     Append STR to output filenames (e.g. _smoke)
#'
#' Cloud sync: reads CP_CMD and DEST_PREFIX from the environment (set by
#' cloud_setup.sh do_recovery). No-op if either is unset (safe for local use).
#'
#' Smoke-test example (no S3, 2 tries of 5 iterations):
#'   Rscript R/model_fitting/fit_recovery_cloud.R 260525_model1_extended.rds 1 \
#'     --max-tries 2 --step-size 5 --save-every 1 --suffix _smoke
#' =============================================================================

library(EMC2)

local({
  root <- Sys.getenv("PAF_REPO_ROOT", unset = "")
  if (nzchar(root)) source(file.path(root, "R", "model_fitting", "helpers", "recovery.R"))
  else              source("R/model_fitting/helpers/recovery.R")
})

RNGkind(RNG_KIND)
set.seed(RNG_SEED)


# =============================================================================
#  Cloud sync hook (same pattern as fit_extend_cloud.R)
# =============================================================================

.cloud_hook <- function(rds_path, log_path) {
  cp_cmd      <- Sys.getenv("CP_CMD",      unset = "")
  dest_prefix <- Sys.getenv("DEST_PREFIX", unset = "")
  if (!nzchar(cp_cmd) || !nzchar(dest_prefix)) return(invisible(NULL))
  for (f in c(rds_path, log_path))
    system(paste(cp_cmd, shQuote(f), paste0(dest_prefix, "/")), wait = TRUE)
}


# =============================================================================
#  Argument parsing
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) < 2) {
  stop(
    "Usage: Rscript fit_recovery_cloud.R <extended_rds> <sim_index> [options]\n",
    "Example: Rscript R/model_fitting/fit_recovery_cloud.R 260525_model1_extended.rds 1\n",
    "Smoke:   Rscript R/model_fitting/fit_recovery_cloud.R 260525_model1_extended.rds 1 ",
    "--fit-samples 5 --max-tries 1 --step-size 5 --save-every 1 --suffix _smoke"
  )
}

extended_rds <- args[[1]]
sim_index    <- as.integer(args[[2]])

if (is.na(sim_index) || sim_index < 1L) {
  stop(sprintf("Invalid sim_index '%s': must be a positive integer.", args[[2]]))
}

.parse_int_arg <- function(args, flag) {
  idx <- which(args == flag)
  if (length(idx) > 0L && idx[[1L]] < length(args)) as.integer(args[[idx[[1L]] + 1L]]) else NULL
}
.parse_str_arg <- function(args, flag) {
  idx <- which(args == flag)
  if (length(idx) > 0L && idx[[1L]] < length(args)) args[[idx[[1L]] + 1L]] else NULL
}

max_tries_override    <- .parse_int_arg(args, "--max-tries")
step_size_override    <- .parse_int_arg(args, "--step-size")
save_every_override   <- .parse_int_arg(args, "--save-every")
fit_samples_override  <- .parse_int_arg(args, "--fit-samples")
suffix_override       <- .parse_str_arg(args, "--suffix")

suffix <- if (!is.null(suffix_override)) suffix_override else ""

# Derive model name from rds filename: strip date prefix + _extended suffix chain
orig_name    <- sub("^[0-9]{6}_", "", tools::file_path_sans_ext(extended_rds))
orig_name    <- sub("(_extended)+$", "", orig_name)
recovery_name <- sprintf("%s_recovery_sim%d%s", orig_name, sim_index, suffix)

# Ensure output directory exists before writing the log
if (!dir.exists(MODELS_RECOVERY_DIR)) dir.create(MODELS_RECOVERY_DIR, recursive = TRUE)

# Per-run log file in MODELS_RECOVERY_DIR
log_file <- file.path(MODELS_RECOVERY_DIR,
                      sprintf("log_recovery_%s_sim%d%s.txt", orig_name, sim_index, suffix))
cat("", file = log_file, append = FALSE)  # fresh log for each invocation

log_msg(sprintf("===== RECOVERY: %s  sim=%d =====", extended_rds, sim_index),
        log_file, console_print = TRUE)
log_msg(sprintf("Output name: %s", recovery_name), log_file, console_print = TRUE)

if (!is.null(fit_samples_override))
  log_msg(sprintf("Override: --fit-samples %d", fit_samples_override), log_file, console_print = TRUE)
if (!is.null(max_tries_override))
  log_msg(sprintf("Override: --max-tries %d",   max_tries_override),   log_file, console_print = TRUE)
if (!is.null(step_size_override))
  log_msg(sprintf("Override: --step-size %d",   step_size_override),   log_file, console_print = TRUE)
if (!is.null(save_every_override))
  log_msg(sprintf("Override: --save-every %d",  save_every_override),  log_file, console_print = TRUE)
if (!is.null(suffix_override))
  log_msg(sprintf("Override: --suffix %s",       suffix_override),      log_file, console_print = TRUE)


# =============================================================================
#  Main execution
# =============================================================================

result <- tryCatch({

  # --- 1. Load extended model ---
  ext_path <- file.path(MODELS_EXTEND_DIR, extended_rds)
  log_msg(sprintf("Loading extended model from: %s", ext_path), log_file, console_print = TRUE)
  extended_model <- readRDS(ext_path)

  # --- 2. Load and filter empirical data (template for trial structure) ---
  log_msg(sprintf("Loading template data from: %s", DATA_FILE), log_file, console_print = TRUE)
  raw_data      <- load_safe_csv(DATA_FILE)
  template_data <- filter_data(raw_data,
                               min_rt               = MIN_SACCADE_CUTOFF,
                               max_rt               = MAX_SACCADE_CUTOFF,
                               allow_target_repeats = ALLOW_TARGET_REPEAT)
  log_msg(sprintf("Template data: %d trials, %d subjects",
                  nrow(template_data), dplyr::n_distinct(template_data$subjects)),
          log_file, console_print = TRUE)

  # --- 3. Extract group-level parameters ---
  log_msg("Extracting group parameters (mu, Sigma)...", log_file, console_print = TRUE)
  group_params <- extract_group_params(extended_model)
  log_msg(sprintf("  mu: %d parameters", length(group_params$mu)), log_file, console_print = TRUE)
  log_msg(sprintf("  Sigma: %dx%d matrix", nrow(group_params$Sigma), ncol(group_params$Sigma)),
          log_file, console_print = TRUE)

  # --- 4. Simulate recovery dataset ---
  sim_seed <- RECOVERY_BASE_SEED + sim_index
  log_msg(sprintf("Simulating recovery data (seed = %d)...", sim_seed), log_file, console_print = TRUE)
  sim_result   <- simulate_recovery_data(extended_model, group_params, template_data, seed = sim_seed)
  sim_data     <- sim_result$data
  true_alpha   <- sim_result$subject_pars
  log_msg(sprintf("  Simulated: %d trials, %d subjects",
                  nrow(sim_data), dplyr::n_distinct(sim_data$subjects)),
          log_file, console_print = TRUE)

  # Save true alpha alongside the recovered model (needed by examine_recovery.R)
  run_date      <- format(Sys.Date(), "%y%m%d")
  true_alpha_path <- file.path(MODELS_RECOVERY_DIR,
                               sprintf("%s_%s_true_alpha.rds", run_date, recovery_name))
  if (!dir.exists(MODELS_RECOVERY_DIR)) dir.create(MODELS_RECOVERY_DIR, recursive = TRUE)
  saveRDS(true_alpha, true_alpha_path)
  log_msg(sprintf("Saved true subject params: %s", true_alpha_path), log_file, console_print = TRUE)
  .cloud_hook(true_alpha_path, log_file)

  # --- 5. Source model script to get build_model() ---
  # Map model name to its script (model1 -> model1.R, etc.)
  model_script <- file.path("R", "model_fitting", paste0(orig_name, ".R"))
  root <- Sys.getenv("PAF_REPO_ROOT", unset = "")
  if (nzchar(root)) model_script <- file.path(root, model_script)
  if (!file.exists(model_script)) {
    stop(sprintf("Model script not found: %s", model_script))
  }
  log_msg(sprintf("Sourcing model script: %s", model_script), log_file, console_print = TRUE)
  source(model_script)   # defines build_model() and MODEL_NAME

  # --- 6. Build fresh model object on simulated data ---
  log_msg("Building fresh model on simulated data...", log_file, console_print = TRUE)
  fresh_model <- build_model(sim_data, n_chains = N_CHAINS)

  # --- 7. Initial fit (all EMC2 phases: preburn -> burn -> adapt -> sample) ---
  core_args    <- get_core_args(N_CHAINS)
  fit_samples  <- if (!is.null(fit_samples_override)) fit_samples_override else RECOVERY_FIT_SAMPLES
  log_msg(
    sprintf("Initial fit: iter=%d, cores_for_chains=%d, cores_per_chain=%d",
            fit_samples, core_args$cores_for_chains, core_args$cores_per_chain),
    log_file, console_print = TRUE
  )
  fitted_model <- fit(
    fresh_model,
    cores_for_chains = core_args$cores_for_chains,
    cores_per_chain  = core_args$cores_per_chain,
    iter             = fit_samples
  )

  # Checkpoint after initial fit
  saved_path <- save_model(fitted_model, recovery_name, MODELS_RECOVERY_DIR,
                           date_prefix = run_date)
  log_msg(sprintf("Post-fit checkpoint: %s", saved_path), log_file, console_print = TRUE)
  .cloud_hook(saved_path, log_file)

  # --- 8. Extend with relaxed convergence criteria ---
  log_msg("Extending with relaxed convergence criteria...", log_file, console_print = TRUE)
  extend_result <- extend_model(
    rds_filename          = basename(saved_path),
    log_file              = log_file,
    source_dir            = MODELS_RECOVERY_DIR,
    models_dir            = MODELS_RECOVERY_DIR,
    extended_fit_samples  = fit_samples,
    max_tries             = if (!is.null(max_tries_override))  max_tries_override  else MAX_TRIES,
    step_size             = if (!is.null(step_size_override))  step_size_override  else STEP_SIZE,
    max_rhat_mu           = MAX_RHAT_MU_RECOVERY,
    min_ess_mu            = MIN_ESS_MU_RECOVERY,
    max_rhat_alpha        = MAX_RHAT_ALPHA_RECOVERY,
    min_ess_alpha         = MIN_ESS_ALPHA_RECOVERY,
    save_every            = if (!is.null(save_every_override)) save_every_override else SAVE_EVERY,
    name_suffix           = suffix,
    post_save_hook        = .cloud_hook
  )

  "COMPLETE"

}, error = function(e) {
  log_error(e, log_file, context = sprintf("recovery('%s', sim=%d)", extended_rds, sim_index))
  "ERROR"
})

log_msg(sprintf("===== %s: %s =====", recovery_name, result), log_file, console_print = TRUE)
