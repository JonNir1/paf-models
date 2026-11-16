#' =============================================================================
#'                    --- MCMC Convergence Diagnostics ---
#'
#' Builds the cross-model convergence table (Rhat & ESS per block) for the active
#' model set and appends the step-2.9 verdict (pass / marginal / descriptive).
#' Writes outputs/evaluation/convergence.{rds,csv}.
#'
#' Goodness-of-fit / model comparison (DIC, BPIC, ...) is NOT here -- see
#' R/eval/model_comparison.R (step-3 scaffolding).
#'
#' Run from the repo root:  source("R/eval/convergence.R")
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")              # transitively: utils.R -> config.R
source_root("R/eval/helpers/io.R")               # load_model, save_eval_table, eval_cache_fresh
source_root("R/eval/helpers/convergence.R")      # create_convergence_table, add_convergence_verdict


# ------------------------------
# Load the active model set (every fitted model in MODELS_FIT_DIR)

MODEL_NAMES <- discover_model_names()
if (length(MODEL_NAMES) == 0)
  stop(sprintf("No fitted models found in %s; fit models before running convergence.", MODELS_FIT_DIR))

MODEL_PATHS <- vapply(MODEL_NAMES, latest_model_path, character(1), dir_path = MODELS_FIT_DIR)


# ------------------------------
# Convergence table (cached: recompute iff a model is newer or the cache key changed)

conv_stem <- "convergence"
conv_rds  <- file.path(EVAL_DIR, paste0(conv_stem, ".rds"))

conv_key <- list(models = MODEL_NAMES,
                 thresholds = c(MAX_RHAT_MU, MIN_ESS_MU, MAX_RHAT_ALPHA, MIN_ESS_ALPHA),
                 emc2 = emc_version())

if (eval_cache_fresh(conv_rds, MODEL_PATHS, conv_key)) {
  message("Convergence table is current (newer than all model fits, same settings); loading cache...")
  CONV_TABLE <- readRDS(conv_rds)
} else {
  message("Recomputing convergence table (cache missing, a model fit is newer, or settings changed)...")
  MODEL_LIST <- lapply(MODEL_NAMES, load_model, dir_path = MODELS_FIT_DIR)
  names(MODEL_LIST) <- MODEL_NAMES
  CONV_TABLE <- add_convergence_verdict(create_convergence_table(MODEL_LIST))
  save_eval_table(CONV_TABLE, conv_stem, cache_key = conv_key)
}

print(CONV_TABLE)
