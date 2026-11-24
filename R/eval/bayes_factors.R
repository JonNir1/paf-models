#' =============================================================================
#' Bayes Factors via bridge sampling (step 3) -- driver
#'
#' Log marginal likelihood (MLL) of every fitted model (discovered in
#' MODELS_FIT_DIR) from EMC2's Warp-III bridge sampling, with BF_REPS repetitions
#' per model, and the log Bayes factors against a reference model (spread across
#' repetitions shown). Complements the DIC/BPIC/LOO of goodness_of_fit.R, which
#' is unchanged (compare() does not compute Bayes factors).
#'
#' Bridge sampling is slow, so each fit's MLL is computed once and stored as an MLL
#' file in MODELS_BF_DIR (by scripts/run_bf.sh on the cloud, see R/fit/fit_bf_cloud.R).
#' This driver PREFERS those precomputed files (one whose recorded fit is the
#' model's current latest fit) and computes locally, writing the file, only for
#' models that lack one.
#'
#' Reference model: BF_REFERENCE (a model name; NULL = highest median MLL). Set it,
#' and BF_REPS, as R variables before sourcing to override the config.
#'
#' Writes (BF_DIR, outputs/evaluation/bayes_factors/):
#'   bayes_factors.{rds,csv}  -- see bf_table(); cached on the model files, MLL
#'                               files, BF_REPS, reference and EMC2 version.
#'
#' Run from the repo root:  source("R/eval/bayes_factors.R")
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")        # BF_REPS, BF_DIR, MODELS_BF_DIR
source_root("R/eval/helpers/io.R")         # latest_model_path, save_eval_table, eval_cache_fresh
source_root("R/eval/helpers/bf.R")         # get_mll, bf_table

if (!exists("BF_REFERENCE")) BF_REFERENCE <- NULL

MODEL_NAMES <- discover_model_names()
if (length(MODEL_NAMES) == 0)
  stop(sprintf("No fitted models found in %s; fit models before running bayes_factors.", MODELS_FIT_DIR))
MODEL_PATHS <- vapply(MODEL_NAMES, latest_model_path, character(1), dir_path = MODELS_FIT_DIR)

bf_cache <- file.path(BF_DIR, "bayes_factors.rds")
bf_key   <- list(models = MODEL_NAMES, files = basename(MODEL_PATHS), reps = BF_REPS,
                 reference = BF_REFERENCE, emc2 = emc_version())

# Inputs for the mtime check: the fits plus whatever MLL files exist now (a new or
# recomputed MLL file is newer than the cache and so invalidates it).
mll_inputs <- list.files(MODELS_BF_DIR, pattern = "_mll\\.rds$", full.names = TRUE)

if (eval_cache_fresh(bf_cache, c(MODEL_PATHS, mll_inputs), bf_key)) {
  message("Bayes-factor cache is current (newer than all fits and MLL files, same settings); loading from disk.")
  BF_TABLE <- readRDS(bf_cache)
} else {
  MLL_RECORDS <- lapply(MODEL_PATHS, get_mll, reps = BF_REPS)
  names(MLL_RECORDS) <- MODEL_NAMES

  BF_TABLE <- bf_table(lapply(MLL_RECORDS, `[[`, "mll"), reference = BF_REFERENCE,
                       n_split_warnings = vapply(MLL_RECORDS, `[[`, integer(1), "n_split_warnings"))
  save_eval_table(BF_TABLE, "bayes_factors", dir = BF_DIR, cache_key = bf_key)
}

print(BF_TABLE)
