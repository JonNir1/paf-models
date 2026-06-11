#' =============================================================================
#' Posterior Predictive Check - Cloud Simulation Driver (step 4)
#'
#' Generates T posterior predictive datasets for one model on a cloud VM.
#' No MCMC refitting -- this is pure simulation from the posterior.
#'
#' For each call:
#'   1. Load a previously-extended model (.rds from fit_extend/)
#'   2. Sample T sets of subject parameters directly from the posterior via
#'      sample_posterior_alphas() -- no MVN approximation
#'   3. For each draw, simulate a full dataset via make_data()
#'   4. Save the list of T simulated data frames to .rds; sync to S3/GCS
#'
#' The simulation pipeline (steps 2-4) is exposed as run_ppc_simulation() so
#' smoke tests can drive it with a small template_data without loading real data.
#'
#' Usage (called by scripts/run_ppc.sh, or directly for local testing):
#'   Rscript R/fit/fit_ppc_cloud.R <extended_rds> [options]
#'   e.g.: Rscript R/fit/fit_ppc_cloud.R 260525_model1_extended.rds
#'
#' Optional overrides (default to eval_config.R / fit_config.R globals):
#'   --n-draws N     Number of posterior draws to simulate (default: PPC_N_DRAWS)
#'   --save-every N  Checkpoint every N draws and sync to S3 (default: 100; 0 = end only)
#'   --suffix STR    Append STR to output filename (e.g. _smoke)
#'
#' Cloud sync: reads CP_CMD and DEST_PREFIX from the environment (set by
#' scripts/run_ppc.sh). No-op if either is unset (safe for local use).
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/recovery.R")   # sample_posterior_alphas, extract_design
source_root("R/eval/eval_config.R")       # PPC_N_DRAWS, PPC_MODELS_DIR via MODELS_EXTEND_DIR


# =============================================================================
#' PPC simulation pipeline (callable; no CLI / no I/O of inputs).
#'
#' Given an already-loaded fitted model and template data, draws n_draws
#' posterior predictive datasets and returns them as a list.
#'
#' @param extended_model  Loaded EMC2 model object (output of fit_extend).
#' @param template_data   Filtered design-matrix data frame providing trial
#'                         structure for make_data(). May be a subset for tests.
#' @param ppc_name        Base name for the output .rds file (without date prefix).
#' @param log_file        Path to write timestamped progress lines.
#' @param out_dir         Directory for the output .rds file.
#' @param n_draws         Number of posterior predictive draws to simulate.
#' @param save_every      Save + sync a checkpoint every N draws (0 = end only).
#' @param sim_seed        Integer RNG seed for sample_posterior_alphas().
#' @param name_suffix     Suffix appended to output filename.
#' @param post_save_hook  Optional function(rds_path, log_path) for cloud sync.
#' @return List of n_draws simulated data frames (same structure as template_data,
#'   with rt and R replaced by simulated values). Side effect: writes output .rds.
run_ppc_simulation <- function(extended_model, template_data,
                               ppc_name, log_file, out_dir,
                               n_draws       = PPC_N_DRAWS,
                               save_every    = 100L,
                               sim_seed      = NULL,
                               name_suffix   = "",
                               post_save_hook = NULL) {

  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  run_date <- format(Sys.Date(), "%y%m%d")
  if (is.null(post_save_hook)) post_save_hook <- function(...) invisible(NULL)

  log_msg(sprintf("Template data: %d trials, %d subjects",
                  nrow(template_data), dplyr::n_distinct(template_data$subjects)),
          log_file, console_print = TRUE)
  log_msg(sprintf("Posterior predictive draws: %d  (checkpoint every %d)",
                  n_draws, if (save_every > 0L) save_every else n_draws),
          log_file, console_print = TRUE)

  # --- 1. Sample posterior alphas ---
  log_msg("Sampling posterior alpha draws...", log_file, console_print = TRUE)
  alpha_list <- sample_posterior_alphas(extended_model, n_draws = n_draws,
                                        seed = sim_seed)
  log_msg(sprintf("  Sampled %d draws x %d subjects x %d parameters",
                  length(alpha_list),
                  if (length(alpha_list) > 0L) nrow(alpha_list[[1L]]) else 0L,
                  if (length(alpha_list) > 0L) ncol(alpha_list[[1L]]) else 0L),
          log_file, console_print = TRUE)

  design_obj <- extract_design(extended_model)

  # Output path is fixed upfront; checkpoints overwrite the same file.
  out_name <- sprintf("%s_%s_ppc%s.rds", run_date, ppc_name, name_suffix)
  out_path <- file.path(out_dir, out_name)

  # --- 2. Simulate one dataset per draw ---
  log_msg("Simulating posterior predictive datasets...", log_file, console_print = TRUE)
  sim_list <- vector("list", length(alpha_list))
  n_failed <- 0L

  for (i in seq_along(alpha_list)) {
    sim_i <- tryCatch(
      make_data(alpha_list[[i]], design_obj, data = template_data),
      error = function(e) {
        log_msg(sprintf("  draw %d: make_data() error: %s", i, conditionMessage(e)),
                log_file, console_print = TRUE)
        FALSE
      }
    )
    if (isFALSE(sim_i)) {
      n_failed <- n_failed + 1L
      sim_list[[i]] <- NULL
    } else {
      sim_list[[i]] <- sim_i
    }

    # Progress log every 10 draws
    if (i %% 10L == 0L || i == length(alpha_list)) {
      log_msg(sprintf("  %d / %d draws complete (%d failed)",
                      i, length(alpha_list), n_failed),
              log_file, console_print = TRUE)
    }

    # Checkpoint: save + sync every save_every draws and always at the end
    is_checkpoint <- (save_every > 0L && i %% save_every == 0L) ||
                     i == length(alpha_list)
    if (is_checkpoint) {
      completed_so_far <- Filter(Negate(is.null), sim_list[seq_len(i)])
      saveRDS(completed_so_far, out_path)
      log_msg(sprintf("  Checkpoint: %d draws -> %s", length(completed_so_far), out_path),
              log_file, console_print = TRUE)
      post_save_hook(out_path, log_file)
    }
  }

  completed <- Filter(Negate(is.null), sim_list)
  log_msg(sprintf("Simulation complete: %d successful draws (of %d requested).",
                  length(completed), n_draws),
          log_file, console_print = TRUE)

  if (length(completed) == 0L) {
    stop("All make_data() calls failed. Check posterior alpha dimensions vs design.")
  }

  invisible(completed)
}


# =============================================================================
# CLI wrapper.  Triggers only when run with CLI args; tests can `source()` this
# file to access run_ppc_simulation() without launching a simulation.
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)

if (length(args) == 0L) {
  # File was sourced (e.g. from a smoke test) -- just expose run_ppc_simulation().
} else if (length(args) < 1L) {
  stop(
    "Usage: Rscript fit_ppc_cloud.R <extended_rds> [options]\n",
    "Example: Rscript R/fit/fit_ppc_cloud.R 260525_model1_extended.rds\n",
    "Smoke:   Rscript R/fit/fit_ppc_cloud.R 260525_model1_extended.rds ",
    "--n-draws 5 --suffix _smoke"
  )
} else {

  RNGkind(RNG_KIND)
  set.seed(RNG_SEED)

  # ---- Cloud sync hook ----
  .cloud_hook <- function(rds_path, log_path) {
    cp_cmd      <- Sys.getenv("CP_CMD",      unset = "")
    dest_prefix <- Sys.getenv("DEST_PREFIX", unset = "")
    if (!nzchar(cp_cmd) || !nzchar(dest_prefix)) return(invisible(NULL))
    for (f in c(rds_path, log_path))
      system(paste(cp_cmd, shQuote(f), paste0(dest_prefix, "/")), wait = TRUE)
  }

  extended_rds <- args[[1L]]

  n_draws_override    <- parse_int_arg(args, "--n-draws")
  save_every_override <- parse_int_arg(args, "--save-every")
  suffix_override     <- parse_str_arg(args, "--suffix")
  suffix <- if (!is.null(suffix_override)) suffix_override else ""

  # Derive model name from rds filename: strip date prefix + _extended suffix
  ppc_name <- sub("^[0-9]{6}_", "", tools::file_path_sans_ext(extended_rds))
  ppc_name <- sub("(_extended)+$", "", ppc_name)

  ppc_out_dir <- file.path(MODELS_DIR, "fit_ppc")
  if (!dir.exists(ppc_out_dir)) dir.create(ppc_out_dir, recursive = TRUE)

  log_file <- file.path(ppc_out_dir,
                        sprintf("log_ppc_%s%s.txt", ppc_name, suffix))
  cat("", file = log_file, append = FALSE)

  log_msg(sprintf("===== PPC SIMULATION: %s =====", extended_rds),
          log_file, console_print = TRUE)
  log_msg(sprintf("Output name: %s_ppc%s", ppc_name, suffix),
          log_file, console_print = TRUE)
  if (!is.null(n_draws_override))
    log_msg(sprintf("Override: --n-draws %d", n_draws_override),
            log_file, console_print = TRUE)
  if (!is.null(save_every_override))
    log_msg(sprintf("Override: --save-every %d", save_every_override),
            log_file, console_print = TRUE)
  if (nzchar(suffix))
    log_msg(sprintf("Override: --suffix %s", suffix), log_file, console_print = TRUE)

  result <- tryCatch({
    ext_path <- file.path(MODELS_EXTEND_DIR, extended_rds)
    log_msg(sprintf("Loading extended model from: %s", ext_path),
            log_file, console_print = TRUE)
    extended_model <- readRDS(ext_path)

    log_msg(sprintf("Loading template data from raw CSVs in: %s", DATA_DIR),
            log_file, console_print = TRUE)
    template_data <- load_data(min_rt               = MIN_SACCADE_CUTOFF,
                               max_rt               = MAX_SACCADE_CUTOFF,
                               allow_target_repeats = ALLOW_TARGET_REPEAT)

    run_ppc_simulation(
      extended_model = extended_model,
      template_data  = template_data,
      ppc_name       = ppc_name,
      log_file       = log_file,
      out_dir        = ppc_out_dir,
      n_draws        = if (!is.null(n_draws_override))    n_draws_override    else PPC_N_DRAWS,
      save_every     = if (!is.null(save_every_override)) save_every_override else 100L,
      sim_seed       = RNG_SEED,
      name_suffix    = suffix,
      post_save_hook = .cloud_hook
    )
    "COMPLETE"
  }, error = function(e) {
    log_error(e, log_file,
              context = sprintf("ppc('%s')", extended_rds))
    "ERROR"
  })

  log_msg(sprintf("===== %s_ppc%s: %s =====", ppc_name, suffix, result),
          log_file, console_print = TRUE)
}
