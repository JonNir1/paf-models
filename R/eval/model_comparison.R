#' =============================================================================
#'                    --- Model Comparison / Goodness of Fit ---
#'
#' SCAFFOLDING for steps 3.X. Relocated out of the convergence script so that
#' convergence (step 2.9) and model comparison (step 3) stay cleanly separated.
#'
#' Currently computes the EMC2 information criteria available via compare()
#' (DIC, BPIC, EffectiveN, mean log-likelihood). The step-3 plan additionally
#' calls for WAIC and PSIS-LOO-CV (with Pareto-k) as the primary criteria, and
#' explicitly NO Bayes Factors (priors are not grounded enough to trust marginal-
#' likelihood ratios). A future agent picking up step 3 should extend
#' create_goodness_of_fit_table() (or add sibling functions) accordingly and add
#' the corresponding L1/L2/L3 tests.
#'
#' Writes outputs/evaluation/model_comparison.{rds,csv}.
#'
#' Run from the repo root:  source("R/eval/model_comparison.R")
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")              # transitively: utils.R -> config.R
source_root("R/eval/helpers/io.R")               # load_model, save_eval_table, newer_than_inputs


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


# ------------------------------
# Driver: build + persist the GoF table for the active model set.
# Sourcing this file runs compare() (which can be slow). Set the env var
# PAF_SKIP_MODEL_COMPARISON=1 to source it for the function definition only
# (e.g. from tests) without triggering the comparison.

if (!nzchar(Sys.getenv("PAF_SKIP_MODEL_COMPARISON"))) {
  MODEL_NAMES <- c("model1", "model2", "model4", "model5")
  MODEL_LIST  <- lapply(MODEL_NAMES, load_model, dir_path = MODELS_EXTEND_DIR)
  names(MODEL_LIST) <- MODEL_NAMES

  FIT_TABLE <- create_goodness_of_fit_table(
    MODEL_LIST, calc_bayes_factors = FALSE, verbose = FALSE
  )
  save_eval_table(FIT_TABLE, "model_comparison")
  print(FIT_TABLE)
}
