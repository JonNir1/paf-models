#' =============================================================================
#'                    --- Goodness of Fit (step 3) ---
#'
#' Computes all step-3 model-comparison criteria for the active model set
#' (model1, model2, model4, model5):
#'
#'   DIC / BPIC  -- via EMC2::compare(); fast, always recomputed.
#'                  DIC reported only; BPIC for screening.
#'   PSIS-LOO-CV -- primary decision criterion; slow, mtime-cached.
#'   WAIC        -- confirmatory; computed alongside LOO.
#'
#' No Bayes Factors (priors not grounded enough to trust marginal-likelihood
#' ratios -- pre-registered).
#'
#' Set PAF_LOO_CORES to parallelise LOO extraction over subjects (default 1;
#' on Windows mclapply falls back to serial regardless).
#'
#' Writes:
#'   outputs/evaluation/dic_bpic.{rds,csv}
#'   outputs/evaluation/loo/loo_table.{rds,csv}
#'   outputs/evaluation/loo/loo_comparison.{rds,csv}
#'   outputs/evaluation/loo/pareto_k_per_model.png
#'   outputs/evaluation/loo/loo_comparison.png
#'
#' Run from the repo root:  source("R/eval/goodness_of_fit.R")
#' =============================================================================

library(EMC2)
library(loo)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")        # transitively: utils.R -> config.R
source_root("R/eval/helpers/io.R")         # load_model, save_eval_table, newer_than_inputs
source_root("R/eval/helpers/gof.R")        # all GoF helpers + create_* functions
source_root("R/eval/helpers/plot.R")       # plot_pareto_k, plot_loo_comparison, save_ggplot_png


# ------------------------------
# Load active model set

MODEL_NAMES <- c("model1", "model2", "model4", "model5")

MODEL_PATHS <- vapply(MODEL_NAMES, function(mn) {
  pattern <- paste0(".*_", mn, "(_extended)?\\.rds$")
  files   <- list.files(MODELS_EXTEND_DIR, full.names = TRUE)
  matches <- files[grepl(pattern, basename(files))]
  if (length(matches) == 0) stop(sprintf("No fit for %s in %s", mn, MODELS_EXTEND_DIR))
  dates <- as.Date(sub("_.*", "", basename(matches)), format = "%y%m%d")
  matches[which.max(dates)]
}, character(1))

MODEL_LIST <- lapply(MODEL_NAMES, load_model, dir_path = MODELS_EXTEND_DIR)
names(MODEL_LIST) <- MODEL_NAMES


# ------------------------------
# DIC / BPIC  (fast; no caching)

DIC_BPIC_TABLE <- create_goodness_of_fit_table(MODEL_LIST)
save_eval_table(DIC_BPIC_TABLE, "dic_bpic")
print(DIC_BPIC_TABLE)


# ------------------------------
# LOO / WAIC  (slow; mtime-cached)

LOO_CORES <- as.integer(Sys.getenv("PAF_LOO_CORES", unset = "1"))
loo_cache  <- file.path(LOO_DIR, "loo_table.rds")

if (newer_than_inputs(loo_cache, MODEL_PATHS)) {
  message("LOO cache is current (newer than all model fits); loading from disk.")
  LOO_TABLE <- readRDS(loo_cache)
} else {
  message(sprintf(
    "Computing LOO / WAIC with %d core(s) -- this takes several minutes per model...",
    LOO_CORES
  ))

  LOO_TABLE <- create_loo_table(MODEL_LIST, cores = LOO_CORES)
  save_eval_table(LOO_TABLE, "loo_table", dir = LOO_DIR)

  loo_objs        <- lapply(MODEL_NAMES, function(nm)
    readRDS(file.path(LOO_DIR, paste0(nm, "_loo.rds"))))
  names(loo_objs) <- MODEL_NAMES

  LOO_COMPARISON  <- make_loo_comparison_df(loo_objs)
  save_eval_table(LOO_COMPARISON, "loo_comparison", dir = LOO_DIR)

  pareto_df <- do.call(rbind, lapply(MODEL_NAMES, function(nm) {
    data.frame(model = nm,
               k_hat = loo_objs[[nm]]$diagnostics$pareto_k,
               stringsAsFactors = FALSE)
  }))
  save_ggplot_png(plot_pareto_k(pareto_df),
                  file.path(LOO_DIR, "pareto_k_per_model.png"), height = 6)
  save_ggplot_png(plot_loo_comparison(LOO_COMPARISON),
                  file.path(LOO_DIR, "loo_comparison.png"), width = 7, height = 5)
}

print(LOO_TABLE)
