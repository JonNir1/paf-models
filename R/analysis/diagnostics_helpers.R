#' =========================
#' Model Diagnostics Helpers
#' =========================
#' A set of helper functions for extracting and parsing model diagnostics:
#' fitting runtime, parameter counts, Rhat & ESS values
#' function `create_diagnostics_table()` returns a unified table for multiple models


#' Create a single table comparing all diagnostic metrics across models and groups
#' @param model_list A named list of models, e.g., list("model_1" = M1, "model_5" = M5)
#' @param log_path Path to the fitting log file
create_diagnostics_table <- function(model_list, log_path) {
  
  master_results <- lapply(names(model_list), function(m_name) {
    runtime <- extract_fit_time(m_name, log_path)
    diag_tables <- extract_convergence_tables(model_list[[m_name]]) # Rhat and ESS
    combined_groups <- merge(
      diag_tables$Rhat, diag_tables$ESS, by = c("group", "n_params")
    )
    final_df <- data.frame(
      model       = m_name,
      runtime_min = runtime,
      combined_groups
    )
    return(final_df)
  })
  
  return(do.call(rbind, master_results))
}


#' Create a Goodness-of-Fit comparison table
#' @param model_list A named list of EMC2 model objects
#' @param log_path Path to the fitting log file
#' @param calc_bayes_factors Logical; passed to compare() BayesFactor argument
#' @param verbose Logical; if TRUE, prints summary from compare()
create_goodness_of_fit_table <- function(
    model_list, log_path, calc_bayes_factors = FALSE, verbose = FALSE
) {
  comp_results <- compare(
    model_list, 
    print_summary = verbose, 
    BayesFactor = calc_bayes_factors, 
    cores_for_props = 4,  # how many cores to use for the Bayes factor calculation
    cores_per_prop = 1    # how many cores to use for the Bayes factor calculation if you have more than 4 cores available
  )
  comp_df <- as.data.frame(comp_results)
  comp_df$model <- rownames(comp_df)
  
  # calculate Mean Log-Likelihood (MLL), based on meanD = -2 * mean(log likelihood)
  comp_df$mean_LL <- comp_df$meanD / -2
  
  # attach runtimes for each model
  comp_df$runtime_min <- sapply(comp_df$model, function(m_name) {
    extract_fit_time(m_name, log_path)
  })
  
  # attach number of parameters the model needed to estimate
  comp_df$num_params <- sapply(model_list, function(m) m[[1]][["n_pars"]])
  
  # Reorganize columns for clarity
  cols_to_keep <- c(
    "model", "num_params", "runtime_min", "EffectiveN", "DIC", "wDIC",
    "BPIC", "wBPIC", "mean_LL", "meanD", "Dmean", "minD"
  )
  if (calc_bayes_factors) {
    # add Bayes Factor columns if they were calculated
    cols_to_keep <- c(cols_to_keep, "BF")
  }
  
  return(comp_df[, cols_to_keep])
}


#' Extracts the fitting duration from the log file
#' @param model_name The name of the model (e.g., "model_5")
#' @param log_path Path to the log.txt file
extract_fit_time <- function(model_name, log_path) {
  if (!file.exists(log_path)) stop(sprintf("Log file not found: %s", log_path))
  
  # Search for the completion line for this specific model script
  # Pattern matches: Finished model_1.R in
  log_lines <- readLines(log_path)
  pattern <- sprintf("Finished %s\\.R in", model_name)
  match_idx <- grep(pattern, log_lines)
  if (length(match_idx) == 0) {
    stop(sprintf("Model '%s' not found in log file.", model_name))
  }
  
  # Verify status is `COMPLETE`
  last_match <- log_lines[match_idx[length(match_idx)]] # Get the last occurrence in case of multiple attempts
  if (!grepl("Status: COMPLETE", last_match)) {
    # Extract whatever status IS there for the error message
    actual_status <- sub(".*Status: ", "", last_match)
    stop(sprintf("Model '%s' found but fitting status was: %s", model_name, actual_status))
  }
  
  # Extract and parse the numeric part
  reg_out <- regmatches(last_match, regexec("in ([0-9.]+) minutes", last_match))
  if (length(reg_out[[1]]) < 2) {
    # Handle cases where the regex might fail despite the grep
    stop(sprintf("Could not parse duration from line: %s", last_match))
  }
  duration <- as.numeric(reg_out[[1]][2])
  return(duration)
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
