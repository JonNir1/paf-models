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
source_root("R/eval/helpers/io.R")               # load_model, save_eval_table, newer_than_inputs
source_root("R/eval/helpers/convergence.R")      # create_convergence_table, add_convergence_verdict


# ------------------------------
# Load the active model set

MODEL_NAMES <- c("model1", "model2", "model4", "model5")
MODEL_PATHS <- vapply(MODEL_NAMES, function(mn) {
  pattern <- paste0(".*_", mn, "(_extended)?\\.rds$")
  files   <- list.files(MODELS_EXTEND_DIR, full.names = TRUE)
  matches <- files[grepl(pattern, basename(files))]
  if (length(matches) == 0) stop(sprintf("No fit for %s in %s", mn, MODELS_EXTEND_DIR))
  dates <- as.Date(sub("_.*", "", basename(matches)), format = "%y%m%d")
  matches[which.max(dates)]
}, character(1))


# ------------------------------
# Convergence table (mtime-cached: recompute iff any model is newer than cache)

conv_stem <- "convergence"
conv_rds  <- file.path(EVAL_DIR, paste0(conv_stem, ".rds"))

if (newer_than_inputs(conv_rds, MODEL_PATHS)) {
  message("Convergence table is current (newer than all model fits); loading cache...")
  CONV_TABLE <- readRDS(conv_rds)
} else {
  message("Recomputing convergence table (cache missing or a model fit is newer)...")
  MODEL_LIST <- lapply(MODEL_NAMES, load_model, dir_path = MODELS_EXTEND_DIR)
  names(MODEL_LIST) <- MODEL_NAMES
  CONV_TABLE <- add_convergence_verdict(create_convergence_table(MODEL_LIST))
  save_eval_table(CONV_TABLE, conv_stem)
}

print(CONV_TABLE)
