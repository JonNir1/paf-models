#' =============================================================================
#'                    --- Model Comparison / Goodness of Fit ---
#'
#' SCAFFOLDING for steps 3.X. Relocated out of the convergence script so that
#' convergence (step 2.9) and model comparison (step 3) stay cleanly separated.
#'
#' Implements step 3: DIC / BPIC via EMC2::compare() (fast, no caching) and
#' PSIS-LOO-CV + WAIC via the loo package (slow, mtime-cached).  Primary model
#' selection criterion is ELPD-LOO; WAIC is confirmatory; DIC is reported only.
#' No Bayes Factors (priors not grounded enough to trust marginal-likelihood
#' ratios).
#'
#' Writes:
#'   outputs/evaluation/model_comparison.{rds,csv}  -- DIC/BPIC table
#'   outputs/evaluation/loo/loo_table.{rds,csv}      -- LOO/WAIC summary
#'   outputs/evaluation/loo/loo_comparison.{rds,csv} -- pairwise ELPD diffs
#'   outputs/evaluation/loo/pareto_k_per_model.png
#'   outputs/evaluation/loo/loo_comparison.png
#'
#' Run from the repo root:  source("R/eval/model_comparison.R")
#' =============================================================================

library(EMC2)
library(loo)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")              # transitively: utils.R -> config.R
source_root("R/eval/helpers/io.R")               # load_model, save_eval_table, newer_than_inputs
source_root("R/eval/helpers/gof.R")              # log_lik_per_trial, extract_log_lik_matrix, loo_summary_row, make_loo_comparison_df
source_root("R/eval/helpers/plot.R")             # plot_pareto_k, plot_loo_comparison, save_ggplot_png


#' Create a Goodness-of-Fit comparison table.
#' @param model_list        Named list of fitted EMC2 model objects.
#' @param calc_bayes_factors Logical; passed to compare(). Default FALSE
#'   (pre-registration: no Bayes Factors).
#' @param verbose           Logical; if TRUE, print compare()'s summary.
#' @return data.frame, one row per model.
create_goodness_of_fit_table <- function(
    model_list, calc_bayes_factors = FALSE, verbose = FALSE
) {
  comp_results <- compare(
    model_list,
    print_summary  = verbose,
    BayesFactor    = calc_bayes_factors,
    cores_for_props = 4,
    cores_per_prop  = 1
  )
  comp_df <- as.data.frame(comp_results)
  comp_df$model <- rownames(comp_df)

  # Mean log-likelihood from meanD = -2 * mean(log likelihood)
  comp_df$mean_LL    <- comp_df$meanD / -2
  comp_df$num_params <- sapply(model_list, function(m) m[[1]][["n_pars"]])

  cols_to_keep <- c(
    "model", "num_params", "EffectiveN", "DIC", "wDIC",
    "BPIC", "wBPIC", "mean_LL", "meanD", "Dmean", "minD"
  )
  if (calc_bayes_factors) cols_to_keep <- c(cols_to_keep, "BF")

  comp_df[, cols_to_keep]
}


#' Build the LOO / WAIC summary table for a list of fitted models.
#'
#' Calls extract_log_lik_matrix() + loo::loo() + loo::waic() per model.
#' Individual loo objects are cached to LOO_DIR/<model_name>_loo.rds so that
#' make_loo_comparison_df() and plot_pareto_k() can load them without
#' recomputing.
#'
#' @param model_list  Named list of fitted EMC2 model objects.
#' @param max_samples Passed to extract_log_lik_matrix() (default 2000).
#' @param cores       Passed to extract_log_lik_matrix() and loo::loo().
#' @return data.frame, one row per model (columns from loo_summary_row()).
create_loo_table <- function(model_list, max_samples = 2000L, cores = 1L) {
  dir.create(LOO_DIR, recursive = TRUE, showWarnings = FALSE)
  rows <- lapply(names(model_list), function(mname) {
    message(sprintf("  [LOO] extracting log-lik matrix for %s ...", mname))
    ll_mat   <- extract_log_lik_matrix(model_list[[mname]], max_samples, cores)
    message(sprintf("  [LOO] running loo::loo() for %s ...", mname))
    loo_obj  <- loo::loo(ll_mat, cores = cores)
    waic_obj <- loo::waic(ll_mat)
    saveRDS(loo_obj, file.path(LOO_DIR, paste0(mname, "_loo.rds")))
    loo_summary_row(mname, loo_obj, waic_obj,
                    pareto_k_threshold = PARETO_K_THRESHOLD,
                    pareto_k_bad_frac  = PARETO_K_BAD_FRAC)
  })
  do.call(rbind, rows)
}


# ------------------------------
# Driver: build + persist the GoF table for the active model set.
# Sourcing this file runs compare() (and optionally LOO, which is slow).
# Set the env var PAF_SKIP_MODEL_COMPARISON=1 to source it for the function
# definitions only (e.g. from tests) without triggering any computation.

if (!nzchar(Sys.getenv("PAF_SKIP_MODEL_COMPARISON"))) {
  MODEL_NAMES <- c("model1", "model2", "model4", "model5")

  # Resolve paths for mtime-based caching (mirrors convergence.R pattern)
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

  # DIC / BPIC (fast; no caching needed)
  FIT_TABLE <- create_goodness_of_fit_table(
    MODEL_LIST, calc_bayes_factors = FALSE, verbose = FALSE
  )
  save_eval_table(FIT_TABLE, "model_comparison")
  print(FIT_TABLE)

  # LOO / WAIC (slow; mtime-cached)
  loo_cache <- file.path(LOO_DIR, "loo_table.rds")
  if (newer_than_inputs(loo_cache, MODEL_PATHS)) {
    message("LOO cache is current; loading loo_table from disk.")
    LOO_TABLE <- readRDS(loo_cache)
  } else {
    message("Computing LOO / WAIC (this takes several minutes per model)...")
    LOO_TABLE <- create_loo_table(MODEL_LIST)
    save_eval_table(LOO_TABLE, "loo_table", dir = LOO_DIR)

    # Pairwise ELPD comparison
    loo_objs        <- lapply(MODEL_NAMES, function(nm) {
      readRDS(file.path(LOO_DIR, paste0(nm, "_loo.rds")))
    })
    names(loo_objs) <- MODEL_NAMES
    LOO_COMPARISON  <- make_loo_comparison_df(loo_objs)
    save_eval_table(LOO_COMPARISON, "loo_comparison", dir = LOO_DIR)

    # Pareto-k and ELPD plots
    pareto_df <- do.call(rbind, lapply(MODEL_NAMES, function(nm) {
      k <- readRDS(file.path(LOO_DIR, paste0(nm, "_loo.rds")))$diagnostics$pareto_k
      data.frame(model = nm, k_hat = k, stringsAsFactors = FALSE)
    }))
    save_ggplot_png(plot_pareto_k(pareto_df),
                    file.path(LOO_DIR, "pareto_k_per_model.png"), height = 6)
    save_ggplot_png(plot_loo_comparison(LOO_COMPARISON),
                    file.path(LOO_DIR, "loo_comparison.png"), width = 7, height = 5)
  }

  print(LOO_TABLE)
}
