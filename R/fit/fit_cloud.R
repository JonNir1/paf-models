#' =============================================================================
#' Unified Model Fitting - Cloud / single-model Runner
#'
#' Fits ONE model to convergence via fit_to_convergence() (helpers/fitting.R).
#' Replaces the retired fit_initial.R + fit_extend_{local,cloud}.R: a single
#' entry point that either builds a fresh model and fits it from scratch, or
#' resumes a previously-saved fit -- the same loop handles both.
#'
#' Designed for parallel cloud execution (one process per model per machine).
#' After every checkpoint the .rds + log are synced to durable storage via a
#' hook reading CP_CMD / DEST_PREFIX from the environment (set by
#' scripts/run_fit.sh). The hook is a no-op when those are unset, so this script
#' also runs locally for testing (outputs stay under outputs/models/fit/).
#'
#' For purely local interactive use you do NOT need this script -- just call
#' fit_to_convergence(emc, ...) directly (see README).
#'
#' Usage (one of --model-script OR --resume is required):
#'   # Build fresh from a model definition and fit to convergence:
#'   Rscript R/fit/fit_cloud.R --model-script R/fit/mymodel.R
#'   # Resume a saved fit (filename under outputs/models/fit/):
#'   Rscript R/fit/fit_cloud.R --resume 260618_mymodel.rds
#'
#' Optional overrides (default to fit_config.R globals / the chosen profile):
#'   --profile STR      Convergence profile: "standard" (default) or "recovery"
#'   --num-samples N    Override the sample-stage floor (convergence_criteria$num_samples)
#'   --max-tries N      Override MAX_TRIES
#'   --batch-size N     Override STEP_SIZE (iters added per try)
#'   --save-every N     Override SAVE_EVERY (checkpoint cadence in tries)
#'   --suffix STR       Append STR to output .rds and log filenames (e.g. _smoke)
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")   # transitively: build_model.R, fit_config.R, data.R, config.R

RNGkind(RNG_KIND)
set.seed(RNG_SEED)


# =============================================================================
#  Cloud sync hook: reads CP_CMD + DEST_PREFIX from the environment at call time
#  (not definition time) so values set by scripts/run_fit.sh are picked up.
#  No-op when either variable is unset.
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

model_script <- parse_str_arg(args, "--model-script")
resume_rds   <- parse_str_arg(args, "--resume")

if (is.null(model_script) && is.null(resume_rds)) {
  stop("Provide exactly one of --model-script <path> (build fresh) or --resume <rds> (resume).\n",
       "Example: Rscript R/fit/fit_cloud.R --model-script R/fit/mymodel.R")
}
if (!is.null(model_script) && !is.null(resume_rds)) {
  stop("--model-script and --resume are mutually exclusive.")
}

profile            <- parse_str_arg(args, "--profile")
if (is.null(profile)) profile <- "standard"
num_samples_over   <- parse_int_arg(args, "--num-samples")
max_tries_over     <- parse_int_arg(args, "--max-tries")
batch_size_over    <- parse_int_arg(args, "--batch-size")
save_every_over    <- parse_int_arg(args, "--save-every")
suffix             <- parse_str_arg(args, "--suffix")
if (is.null(suffix)) suffix <- ""

# --- Resolve the model object + its output name ---
if (!is.null(model_script)) {
  if (!file.exists(model_script)) stop(sprintf("Model script not found: %s", model_script))
  source(model_script)                       # defines build_model() and MODEL_NAME
  model_name <- MODEL_NAME
} else {
  model_name <- sub("^[0-9]{6}_", "", tools::file_path_sans_ext(basename(resume_rds)))
}

run_date  <- format(Sys.Date(), "%y%m%d")
out_name  <- paste0(model_name, suffix)
save_path <- file.path(MODELS_FIT_DIR, sprintf("%s_%s.rds", run_date, out_name))
log_file  <- model_log_path(out_name, MODELS_FIT_DIR)

cat("", file = log_file, append = FALSE)
log_msg(sprintf("===== FIT: %s (%s) =====", out_name,
                if (!is.null(model_script)) "fresh" else "resume"),
        log_file, console_print = TRUE)
log_config_variables(FIT_CONFIG_FILE, log_file)

# --- Build convergence_criteria from the profile + overrides ---
convergence_criteria <- default_convergence_criteria(profile)
if (!is.null(num_samples_over)) convergence_criteria$num_samples <- num_samples_over

max_tries  <- if (!is.null(max_tries_over))  max_tries_over  else MAX_TRIES
batch_size <- if (!is.null(batch_size_over)) batch_size_over else STEP_SIZE
save_every <- if (!is.null(save_every_over)) save_every_over else SAVE_EVERY

result <- tryCatch({
  if (!is.null(model_script)) {
    log_msg(sprintf("Loading data from raw CSVs in: %s", DATA_DIR), log_file, console_print = TRUE)
    clean_data <- load_data(min_rt = MIN_SACCADE_CUTOFF, max_rt = MAX_SACCADE_CUTOFF,
                            allow_target_repeats = ALLOW_TARGET_REPEAT)
    log_msg(sprintf("Data: %d rows, %d subjects",
                    nrow(clean_data), dplyr::n_distinct(clean_data$subjects)),
            log_file, console_print = TRUE)
    emc <- build_model(clean_data, n_chains = N_CHAINS)
  } else {
    in_path <- if (file.exists(resume_rds)) resume_rds else file.path(MODELS_FIT_DIR, resume_rds)
    log_msg(sprintf("Resuming model from: %s", in_path), log_file, console_print = TRUE)
    emc <- readRDS(in_path)
  }

  fit_to_convergence(
    emc,
    convergence_criteria = convergence_criteria,
    max_tries            = max_tries,
    batch_size           = batch_size,
    save_every           = save_every,
    save_path            = save_path,
    post_save_hook       = .cloud_hook,
    log_file             = log_file,
    append_log           = TRUE
  )
  "COMPLETE"
}, error = function(e) {
  log_error(e, log_file, context = sprintf("fit_to_convergence('%s')", out_name))
  "ERROR"
})

log_msg(sprintf("===== %s: %s =====", out_name, result), log_file, console_print = TRUE)
