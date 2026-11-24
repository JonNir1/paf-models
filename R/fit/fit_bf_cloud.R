#' =============================================================================
#' Bayes Factor (marginal likelihood) - Cloud Runner
#'
#' Computes the bridge-sampling log marginal likelihood (MLL) of ONE fitted model
#' on a cloud VM and writes it as an MLL file (see R/eval/helpers/bf.R) that
#' R/eval/bayes_factors.R and R/eval/model_recovery.R read back instead of
#' recomputing. No MCMC refit: bridge sampling only reuses the posterior samples
#' (the fit must be converged). Works on the main fits and on recovery fits.
#'
#' Usage (called by scripts/run_bf.sh, or directly for local testing):
#'   Rscript R/fit/fit_bf_cloud.R <fit_rds> [options]
#'   e.g.: Rscript R/fit/fit_bf_cloud.R 260618_mymodel.rds
#'   <fit_rds> is a path, or a file name under outputs/models/fit/.
#'
#' Optional overrides:
#'   --reps N     Bridge-sampling repetitions (default BF_REPS in eval_config.R)
#'
#' Output: outputs/models/fit_bf/YYMMDD_<stem>_mll.rds + log_bf_<stem>.txt, where
#' <stem> is the fit file's name without date prefix and extension.
#'
#' Cloud sync: reads CP_CMD and DEST_PREFIX from the environment (set by
#' scripts/run_bf.sh). No-op if either is unset (safe for local use).
#' Exits with status 1 on error.
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/fit_config.R")         # transitively: utils.R -> config.R
source_root("R/helpers/logging.R")
source_root("R/eval/eval_config.R")       # BF_REPS, MODELS_BF_DIR
source_root("R/eval/helpers/bf.R")        # run_mll


args <- commandArgs(trailingOnly = TRUE)

if (length(args) == 0L) {
  # File was sourced (e.g. from a test) -- nothing to run.
} else {

  library(EMC2)

  RNGkind(RNG_KIND)
  set.seed(RNG_SEED)

  .cloud_hook <- function(rds_path, log_path) {
    cp_cmd      <- Sys.getenv("CP_CMD",      unset = "")
    dest_prefix <- Sys.getenv("DEST_PREFIX", unset = "")
    if (!nzchar(cp_cmd) || !nzchar(dest_prefix)) return(invisible(NULL))
    for (f in c(rds_path, log_path))
      system(paste(cp_cmd, shQuote(f), paste0(dest_prefix, "/")), wait = TRUE)
  }

  fit_arg       <- args[[1L]]
  reps_override <- parse_int_arg(args, "--reps")
  reps          <- if (!is.null(reps_override)) reps_override else BF_REPS

  fit_path <- if (file.exists(fit_arg)) fit_arg else file.path(MODELS_FIT_DIR, fit_arg)
  stem     <- model_name_from_rds(fit_path)

  if (!dir.exists(MODELS_BF_DIR)) dir.create(MODELS_BF_DIR, recursive = TRUE)
  log_file <- file.path(MODELS_BF_DIR, sprintf("log_bf_%s.txt", stem))
  cat("", file = log_file, append = FALSE)

  log_msg(sprintf("===== BAYES FACTOR (MLL): %s =====", fit_path), log_file, console_print = TRUE)
  log_msg(sprintf("EMC2 version: %s", emc_version()), log_file)
  log_msg(sprintf("Bridge-sampling repetitions: %d", reps), log_file, console_print = TRUE)

  result <- tryCatch({
    mll_path <- run_mll(fit_path, reps, out_dir = MODELS_BF_DIR, seed = RNG_SEED)
    record   <- readRDS(mll_path)
    log_msg(sprintf("MLL per repetition: %s", paste(signif(record$mll, 8), collapse = ", ")),
            log_file, console_print = TRUE)
    log_msg(sprintf("Split-estimate warnings (halves differ by > 1 log point): %d",
                    record$n_split_warnings),
            log_file, console_print = TRUE)
    log_msg(sprintf("Saved: %s", mll_path), log_file, console_print = TRUE)
    .cloud_hook(mll_path, log_file)
    "COMPLETE"
  }, error = function(e) {
    log_error(e, log_file, context = sprintf("bridge sampling('%s')", fit_arg))
    "ERROR"
  })

  log_msg(sprintf("===== %s_mll: %s =====", stem, result), log_file, console_print = TRUE)
  if (identical(result, "ERROR")) quit(status = 1)
}
