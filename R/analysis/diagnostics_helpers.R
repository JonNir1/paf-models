#' =========================
#' Model Diagnostics Helpers
#' =========================
#' A set of helper functions for extracting and parsing model diagnostics:
#' parameter counts, Rhat & ESS values.
#' `create_diagnostics_table()` returns a unified convergence table for multiple models.


#' Create a single table comparing all diagnostic metrics across models and groups
#' @param model_list A named list of models, e.g., list("model_1" = M1, "model_5" = M5)
create_diagnostics_table <- function(model_list) {

  master_results <- lapply(names(model_list), function(m_name) {
    diag_tables <- extract_convergence_tables(model_list[[m_name]])
    combined_groups <- merge(
      diag_tables$Rhat, diag_tables$ESS, by = c("group", "n_params")
    )
    data.frame(model = m_name, combined_groups)
  })

  return(do.call(rbind, master_results))
}


#' Create a Goodness-of-Fit comparison table
#' @param model_list A named list of EMC2 model objects
#' @param calc_bayes_factors Logical; passed to compare() BayesFactor argument
#' @param verbose Logical; if TRUE, prints summary from compare()
create_goodness_of_fit_table <- function(
    model_list, calc_bayes_factors = FALSE, verbose = FALSE
) {
  comp_results <- compare(
    model_list,
    print_summary = verbose,
    BayesFactor = calc_bayes_factors,
    cores_for_props = 4,
    cores_per_prop = 1
  )
  comp_df <- as.data.frame(comp_results)
  comp_df$model <- rownames(comp_df)

  # Mean Log-Likelihood from meanD = -2 * mean(log likelihood)
  comp_df$mean_LL <- comp_df$meanD / -2

  # number of parameters estimated
  comp_df$num_params <- sapply(model_list, function(m) m[[1]][["n_pars"]])

  cols_to_keep <- c(
    "model", "num_params", "EffectiveN", "DIC", "wDIC",
    "BPIC", "wBPIC", "mean_LL", "meanD", "Dmean", "minD"
  )
  if (calc_bayes_factors) cols_to_keep <- c(cols_to_keep, "BF")

  return(comp_df[, cols_to_keep])
}


#' Extract convergence summary tables (Rhat & ESS) for a model
#' @param model The fitted EMC2 model object
#' @param verbose Logical; if TRUE, prints the full check() output to console
extract_convergence_tables <- function(model, verbose = FALSE) {
  # Run check() with selection for all possible groups
  selection_groups <- c("mu", "sigma2", "alpha", "correlation")
  check_call <- function() {
    suppressWarnings(
      check(model, selection = selection_groups, plot_worst = FALSE, digits = 4)
    )
  }
  if (verbose) {
    chk <- check_call()
  } else {
    # capture.output silences the console printing while still returning the object
    capture.output(chk <- check_call())
  }
  
  # Generate Rhat Table (Row 1)
  rhat_table <- do.call(rbind, lapply(selection_groups, function(g) {
    vals <- .get_pooled_values(chk, g, 1)
    stats <- .calc_summary_stats(vals, "Rhat")
    cbind(group = g, stats)
  }))
  # Generate ESS Table (Row 2)
  ess_table <- do.call(rbind, lapply(selection_groups, function(g) {
    vals <- .get_pooled_values(chk, g, 2)
    stats <- .calc_summary_stats(vals, "ESS")
    cbind(group = g, stats)
  }))
  
  return(list(Rhat = rhat_table, ESS = ess_table))
}


#' Internal helper to pull and pool parameters from the check(model) object
.get_pooled_values <- function(chk, group, row_idx) {
  if (group == "alpha") {
    # Pool all subjects into one long vector for the group summary
    return(unlist(lapply(chk$alpha, function(x) x[row_idx, ])))
  }
  # Standard nested indexing: chk[["mu"]][["mu"]][row, ]
  return(chk[[group]][[group]][row_idx, ])
}


#' Internal helper to calculate summary stats for a numeric vector
.calc_summary_stats <- function(vals, type = c("Rhat", "ESS")) {
  type <- match.arg(type)
  n <- length(vals)
  
  if (type == "Rhat") {
    return(data.frame(
      n_params     = n,
      max_rhat         = max(vals, na.rm = TRUE),
      mean_rhat        = mean(vals, na.rm = TRUE),
      n_rhat_gt_1.1    = sum(vals > 1.1, na.rm = TRUE),
      p_rhat_gt_1.1    = (sum(vals > 1.1, na.rm = TRUE) / n) * 100,
      n_rhat_gt_1.01   = sum(vals > 1.01, na.rm = TRUE),
      p_rhat_gt_1.01   = (sum(vals > 1.01, na.rm = TRUE) / n) * 100
    ))
  } else {
    return(data.frame(
      n_params     = n,
      min_ess         = min(vals, na.rm = TRUE),
      mean_ess        = mean(vals, na.rm = TRUE),
      n_ess_lt_500    = sum(vals < 500, na.rm = TRUE),
      p_ess_lt_500    = (sum(vals < 500, na.rm = TRUE) / n) * 100,
      n_ess_lt_1000   = sum(vals < 1000, na.rm = TRUE),
      p_ess_lt_1000   = (sum(vals < 1000, na.rm = TRUE) / n) * 100
    ))
  }
}
