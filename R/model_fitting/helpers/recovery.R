#' =============================================================================
#' Parameter Recovery Helpers (step 2.5)
#'
#' Implements the Strickland et al. (2026) Supplementary recovery protocol:
#'   1. extract_group_params()      -- posterior mean (mu, Sigma) from a fitted model
#'   2. extract_design()            -- design object embedded in a fitted model
#'   3. simulate_recovery_data()    -- draw fresh alpha_i; generate synthetic data
#'
#' Used by fit_recovery_cloud.R and examine_recovery.R.
#'
#' Source chain: recovery.R -> fitting.R -> build_model.R -> data.R -> logging.R -> config.R
#' =============================================================================

local({
  root <- Sys.getenv("PAF_REPO_ROOT", unset = "")
  if (nzchar(root)) source(file.path(root, "R", "model_fitting", "helpers", "fitting.R"))
  else              source("R/model_fitting/helpers/fitting.R")
})


# -------------------------
#' Extract posterior mean mu and covariance Sigma from a fitted EMC2 model.
#'
#' Uses the $mu and $sigma2/$correlation sampling blocks. The covariance matrix
#' is reconstructed as Sigma = diag(SD) %*% Cor %*% diag(SD) from the posterior
#' means of the variance and correlation parameters.
#'
#' NOTE: EMC2 flattens the correlation matrix upper triangle in row-major order.
#' This is verified against EMC2 v3.3.0 internals. If the reconstruction fails
#' (e.g. Sigma is not positive-definite), fall back to variance_proportion in
#' make_random_effects() by passing Sigma = NULL.
#'
#' @param model A fitted EMC2 model object (emc class).
#' @return Named list: mu (named numeric vector), Sigma (named square matrix).
extract_group_params <- function(model) {
  library(EMC2)

  # Helper: combine mcmc.list chains into a plain numeric matrix.
  # as.matrix() strips the mcmc class so rbind + colMeans work reliably.
  .chain_means <- function(samples) {
    mat <- do.call(rbind, lapply(samples, as.matrix))
    colMeans(mat)
  }

  # --- Population means (mu block) ---
  mu_samples <- get_pars(model, selection = "mu", stage = "sample",
                         map = FALSE, return_mcmc = TRUE)
  mu_hat <- .chain_means(mu_samples)

  # --- Covariance: Sigma = E[diag(SD_i) %*% Cor_i %*% diag(SD_i)] ---
  # We average per-sample Sigma matrices rather than averaging variances and
  # correlations separately and then combining. This guarantees positive-
  # definiteness because the mean of PD matrices is PD (convex combination).
  var_samples <- get_pars(model, selection = "sigma2", stage = "sample",
                          return_mcmc = TRUE)
  cor_samples <- get_pars(model, selection = "correlation", stage = "sample",
                          flatten = TRUE, return_mcmc = TRUE)

  var_mat <- do.call(rbind, lapply(var_samples, as.matrix))  # (n_samples x n_pars)
  cor_mat <- do.call(rbind, lapply(cor_samples, as.matrix))  # (n_samples x n_pairs)

  n_pars  <- length(mu_hat)
  SD_mat  <- sqrt(var_mat)                                    # (n_samples x n_pars)
  # EMC2's flatten=TRUE returns the LOWER triangle in column-major order
  # (column names follow the pattern "rowParam.colParam", e.g. "v_PrevTar.v" = (2,1)).
  # We must use lower-triangle indices so that the SD pairs match the correlation columns.
  lt      <- which(lower.tri(diag(n_pars)), arr.ind = TRUE)   # lower-triangle indices

  # Per-sample covariance for each lower-triangle pair (vectorised, no R loop)
  cov_flat  <- cor_mat * SD_mat[, lt[, 1], drop = FALSE] *
                         SD_mat[, lt[, 2], drop = FALSE]  # (n_samples x n_pairs)

  Sigma <- diag(colMeans(var_mat))
  Sigma[lower.tri(Sigma)] <- colMeans(cov_flat)
  Sigma[upper.tri(Sigma)] <- t(Sigma)[upper.tri(Sigma)]
  rownames(Sigma) <- colnames(Sigma) <- names(mu_hat)

  # Validate PD (should always pass with the averaging approach, but guard anyway)
  eig <- tryCatch(eigen(Sigma, only.values = TRUE)$values, error = function(e) NA_real_)
  if (any(is.na(eig)) || any(eig <= 0)) {
    warning(
      "Reconstructed Sigma is still not positive-definite (min eigenvalue = ",
      round(min(eig, na.rm = TRUE), 4), "). ",
      "Check that the model has sufficient sampling-stage iterations."
    )
  }

  list(mu = mu_hat, Sigma = Sigma)
}


# -------------------------
#' Extract the design object embedded in a fitted EMC2 model.
#'
#' The design is stored in the closure environment of the per-chain model
#' function. Needed by make_random_effects() and make_data().
#'
#' @param model A fitted EMC2 model object.
#' @return The design list as created by EMC2::design().
extract_design <- function(model) {
  environment(model[[1]][["model"]])$design
}


# -------------------------
#' Draw fresh subject parameters and simulate a recovery dataset.
#'
#' Implements Strickland et al. (2026) Supplementary protocol:
#'   - make_random_effects() draws n_subj alpha_i ~ MVN(mu_hat, Sigma_hat)
#'   - make_data() replaces real RTs/responses with model-generated values,
#'     preserving the exact trial structure of the empirical data.
#'
#' @param model        Fitted EMC2 model (used only to extract the design).
#' @param group_params List returned by extract_group_params(): $mu and $Sigma.
#' @param template_data Data frame (filtered empirical data) providing trial
#'   structure; RTs and responses are replaced by simulated values.
#' @param seed         Integer RNG seed for reproducibility.
#' @return Named list:
#'   $data         -- simulated data frame (same structure as template_data)
#'   $subject_pars -- matrix of true alpha_i (subjects x parameters)
simulate_recovery_data <- function(model, group_params, template_data, seed) {
  library(EMC2)
  set.seed(seed)

  design_obj <- extract_design(model)

  # Draw fresh subject-level parameters from the fitted group distribution.
  # n_subj = NULL: inferred from template_data (preserves original subject count).
  # Sigma from extract_group_params(); if not PD, fall back to variance_proportion.
  Sigma_ok <- !is.null(group_params$Sigma) &&
    isTRUE(tryCatch(all(eigen(group_params$Sigma, only.values=TRUE)$values > 0),
                    error = function(e) FALSE))

  if (Sigma_ok) {
    subject_pars <- make_random_effects(
      design      = design_obj,
      group_means = group_params$mu,
      n_subj      = NULL,
      covariances = group_params$Sigma
    )
  } else {
    warning("Using variance_proportion = 0.2 fallback (Sigma not positive-definite).")
    subject_pars <- make_random_effects(
      design             = design_obj,
      group_means        = group_params$mu,
      n_subj             = NULL,
      variance_proportion = 0.2
    )
  }

  # Simulate data using the real trial structure as template.
  # make_data() returns FALSE (not a data frame) when >10% of parameter values
  # fall outside model bounds; stop early with a clear message in that case.
  sim_data <- make_data(subject_pars, design_obj, data = template_data)
  if (isFALSE(sim_data)) {
    stop(
      "make_data() returned FALSE: >10% of drawn subject parameters fall ",
      "outside model bounds. This typically means the group-level Sigma is ",
      "too diffuse. Check Sigma eigenvalues from extract_group_params()."
    )
  }

  list(data = sim_data, subject_pars = subject_pars)
}
