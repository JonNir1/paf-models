#' =============================================================================
#' Parameter Recovery Helpers (step 2.5)
#'
#' Implements the Strickland et al. (2026) Supplementary recovery protocol:
#'   1. extract_group_params()      -- posterior mean (mu, Sigma) from a fitted model
#'   2. extract_design()            -- design object embedded in a fitted model
#'   3. simulate_recovery_data()    -- draw fresh alpha_i; generate synthetic data
#'   4. truncate_to_window()        -- optional RT-window truncation of simulated data
#'
#' Used by fit_recovery_cloud.R and examine_recovery.R.
#'
#' Source chain: recovery.R -> fitting.R -> build_model.R -> fit_config.R -> ...
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")


# -------------------------
#' Extract posterior mean mu and covariance Sigma from a fitted EMC2 model.
#'
#' Uses the $mu and $sigma2/$correlation sampling blocks. The covariance matrix
#' is reconstructed as Sigma = diag(SD) %*% Cor %*% diag(SD) from the posterior
#' means of the variance and correlation parameters.
#'
#' NOTE: flatten = TRUE returns the correlation matrix's lower triangle in
#' column-major order, columns named "rowParam.colParam" (verified on real fits
#' under EMC2 3.4.1 and 3.5.0). All blocks are aligned to the mu parameter names
#' by name; a mismatch is an error. If the reconstruction fails
#' (e.g. Sigma is not positive-definite), fall back to variance_proportion in
#' make_random_effects() by passing Sigma = NULL.
#'
#' @param model A fitted EMC2 model object (emc class).
#' @return Named list: mu (named numeric vector), Sigma (named square matrix).
extract_group_params <- function(model) {
  # Helper: combine mcmc.list chains into a plain numeric matrix.
  # as.matrix() strips the mcmc class so rbind + colMeans work reliably.
  .chain_means <- function(samples) {
    mat <- do.call(rbind, lapply(samples, as.matrix))
    colMeans(mat)
  }

  # --- Population means (mu block) ---
  mu_samples <- emc_get_pars(model, selection = "mu", stage = "sample",
                             map = FALSE, return_mcmc = TRUE)
  mu_hat <- .chain_means(mu_samples)

  # --- Covariance: Sigma = E[diag(SD_i) %*% Cor_i %*% diag(SD_i)] ---
  # We average per-sample Sigma matrices rather than averaging variances and
  # correlations separately and then combining. This guarantees positive-
  # definiteness because the mean of PD matrices is PD (convex combination).
  var_samples <- emc_get_pars(model, selection = "sigma2", stage = "sample",
                              return_mcmc = TRUE)
  cor_samples <- emc_get_pars(model, selection = "correlation", stage = "sample",
                              flatten = TRUE, return_mcmc = TRUE)

  var_mat <- do.call(rbind, lapply(var_samples, as.matrix))  # (n_samples x n_pars)
  cor_mat <- do.call(rbind, lapply(cor_samples, as.matrix))  # (n_samples x n_pairs)

  par_names <- names(mu_hat)
  if (!setequal(colnames(var_mat), par_names))
    stop("sigma2 parameter names differ from mu parameter names.")
  var_mat <- var_mat[, par_names, drop = FALSE]

  n_pars  <- length(mu_hat)
  SD_mat  <- sqrt(var_mat)                                    # (n_samples x n_pars)
  # EMC2's flatten=TRUE returns the LOWER triangle in column-major order
  # (column names follow the pattern "rowParam.colParam", e.g. "v_PrevTar.v" = (2,1)).
  # We must use lower-triangle indices so that the SD pairs match the correlation columns.
  lt      <- which(lower.tri(diag(n_pars)), arr.ind = TRUE)   # lower-triangle indices

  pair_names <- paste(par_names[lt[, 1]], par_names[lt[, 2]], sep = ".")
  if (!setequal(colnames(cor_mat), pair_names))
    stop("correlation column names do not match the lower-triangle pairs of the mu parameters.")
  cor_mat <- cor_mat[, pair_names, drop = FALSE]

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
#' Sample T sets of subject-level parameters directly from the posterior.
#'
#' Used by fit_ppc_cloud.R to generate posterior predictive datasets without
#' the MVN approximation used by simulate_recovery_data().
#'
#' get_pars(alpha, return_mcmc=TRUE) returns a parameter-keyed list (length
#' n_pars), each element a [n_samples x n_subjects] matrix (chains collapsed).
#' We evenly subsample n_draws indices to reduce autocorrelation.
#'
#' NOTE: The resulting matrices have named columns matching the parameter space
#' and are intended to be passed directly to make_data(). Verify that column
#' naming matches make_random_effects() output when first running on a real fit.
#'
#' @param model   A fitted EMC2 model (emc class), sampling stage completed.
#' @param n_draws Number of posterior draws to return.
#' @param seed    Optional integer RNG seed (affects draw-index jitter if any).
#' @return List of n_draws matrices, each [n_subjects x n_pars] with named columns.
sample_posterior_alphas <- function(model, n_draws, seed = NULL) {
  if (!is.null(seed)) set.seed(seed)

  alpha_raw <- emc_get_pars(model, selection = "alpha", stage = "sample",
                            map = FALSE, return_mcmc = TRUE)

  # Collapse each element to a plain [n_samples x n_subjects] matrix.
  # Each element may be a plain matrix or an mcmc.list of per-chain matrices.
  par_mats <- lapply(alpha_raw, function(x) {
    if (inherits(x, "mcmc.list") || (is.list(x) && !is.data.frame(x))) {
      do.call(rbind, lapply(x, as.matrix))
    } else {
      as.matrix(x)
    }
  })

  n_samples  <- nrow(par_mats[[1]])
  n_subjects <- ncol(par_mats[[1]])
  par_names  <- names(par_mats)

  if (n_draws > n_samples) {
    warning(sprintf(
      "n_draws (%d) exceeds available posterior samples (%d); using %d draws.",
      n_draws, n_samples, n_samples
    ))
    n_draws <- n_samples
  }

  draw_idx <- unique(round(seq(1, n_samples, length.out = n_draws)))

  lapply(draw_idx, function(i) {
    # vapply(list_of_k, FUN_returning_length_n, ...) -> [n x k] matrix
    mat <- vapply(par_mats, function(m) m[i, ], numeric(n_subjects))
    colnames(mat) <- par_names
    mat
  })
}


# -------------------------
#' Validate an RT window: NULL (untruncated) or c(min, max) with min <= max.
.validate_rt_window <- function(rt_window) {
  if (is.null(rt_window)) return(invisible(NULL))
  if (!is.numeric(rt_window) || length(rt_window) != 2L || anyNA(rt_window) || rt_window[1] > rt_window[2])
    stop("rt_window must be NULL or numeric c(min, max) with min <= max.", call. = FALSE)
  invisible(NULL)
}


# -------------------------
#' Truncate simulated data to an RT window (inclusive, like filter_data()).
#'
#' Rows with `rt` outside `[rt_window[1], rt_window[2]]` are dropped; rows with
#' a missing rt are kept. The window is applied to the simulated data only: the
#' likelihood of the refit is still the untruncated LBA.
#'
#' @param sim_data  Simulated data frame with `rt` and `subjects` columns.
#' @param rt_window NULL (no truncation) or c(min, max) in seconds.
#' @return list(data = the (possibly truncated) data frame, dropped = NULL when
#'   `rt_window` is NULL, else a data frame with one row per subject:
#'   subjects, n, n_dropped, frac_dropped).
truncate_to_window <- function(sim_data, rt_window) {
  .validate_rt_window(rt_window)
  if (is.null(rt_window)) return(list(data = sim_data, dropped = NULL))

  keep <- !(sim_data$rt < rt_window[1] | sim_data$rt > rt_window[2]) | is.na(sim_data$rt)
  subj <- as.character(sim_data$subjects)
  n    <- table(subj)
  nd   <- table(factor(subj[!keep], levels = names(n)))
  list(data = sim_data[keep, , drop = FALSE],
       dropped = data.frame(subjects = names(n), n = as.integer(n), n_dropped = as.integer(nd),
                            frac_dropped = as.integer(nd) / as.integer(n), stringsAsFactors = FALSE))
}


#' Fingerprint of a data frame: row count and md5 of its uncompressed serialization.
#'
#' @param data A data frame (e.g. the template data of a simulation).
#' @return list(nrow, md5).
data_fingerprint <- function(data) {
  path <- tempfile(fileext = ".rds")
  on.exit(unlink(path))
  saveRDS(data, path, compress = FALSE)
  list(nrow = nrow(data), md5 = unname(tools::md5sum(path)))
}


#' Tag simulated output with the RT window it was truncated to (NA = untruncated).
#'
#' @param x         Object to tag (e.g. the list of PPC simulations).
#' @param rt_window NULL or c(min, max).
#' @return `x` with attribute "rt_window".
with_rt_window <- function(x, rt_window) {
  attr(x, "rt_window") <- if (is.null(rt_window)) NA_real_ else rt_window
  x
}


#' Log the dropped fraction of a truncation, overall and per subject.
#'
#' @param dropped   `$dropped` of truncate_to_window() (or per-subject counts
#'   summed over draws); NULL logs nothing.
#' @param rt_window The window that was applied.
#' @param log_file  Log path (NULL = console only).
log_truncation <- function(dropped, rt_window, log_file) {
  if (is.null(dropped)) return(invisible(NULL))
  n_total <- sum(dropped$n)
  pct     <- if (n_total == 0L) 0 else 100 * sum(dropped$n_dropped) / n_total
  log_msg(sprintf("RT window [%s, %s]: dropped %d of %d simulated trials (%.2f%%)",
                  rt_window[1], rt_window[2], sum(dropped$n_dropped), n_total, pct),
          log_file, console_print = TRUE)
  frac <- ifelse(dropped$n == 0L, 0, dropped$n_dropped / dropped$n)
  log_msg(sprintf("  per-subject dropped fraction: %s",
                  paste(sprintf("%s=%.3f", dropped$subjects, frac), collapse = ", ")),
          log_file)
  invisible(NULL)
}


# -------------------------
#' Draw fresh subject parameters and simulate a recovery dataset.
#'
#' Implements Strickland et al. (2026) Supplementary protocol:
#'   - make_random_effects() draws n_subj alpha_i ~ MVN(mu_hat, Sigma_hat)
#'   - make_data() replaces real RTs/responses with model-generated values,
#'     preserving the exact trial structure of the empirical data.
#'   - Simulated RTs are NOT truncated unless `rt_window` is given (e.g. the
#'     observed-RT window MIN/MAX_SACCADE_CUTOFF); the PPC simulations work the
#'     same way. The truncation happens after make_data(), so `subject_pars`
#'     (the true alpha) is unaffected.
#'
#' @param model        Fitted EMC2 model (used only to extract the design).
#' @param group_params List returned by extract_group_params(): $mu and $Sigma.
#' @param template_data Data frame (filtered empirical data) providing trial
#'   structure; RTs and responses are replaced by simulated values.
#' @param seed         Integer RNG seed for reproducibility.
#' @param rt_window     NULL (default, untruncated) or c(min, max) in seconds
#'   (inclusive); simulated trials outside it are dropped.
#' @return Named list:
#'   $data         -- simulated data frame (same structure as template_data)
#'   $subject_pars -- matrix of true alpha_i (subjects x parameters)
#'   $dropped      -- per-subject drop counts (truncate_to_window()); only present when truncated
simulate_recovery_data <- function(model, group_params, template_data, seed, rt_window = NULL) {
  .validate_rt_window(rt_window)
  set.seed(seed)

  design_obj <- extract_design(model)

  # Draw fresh subject-level parameters from the fitted group distribution.
  # n_subj = NULL: inferred from template_data (preserves original subject count).
  # Sigma from extract_group_params(); if not PD, fall back to variance_proportion.
  Sigma_ok <- !is.null(group_params$Sigma) &&
    isTRUE(tryCatch(all(eigen(group_params$Sigma, only.values=TRUE)$values > 0),
                    error = function(e) FALSE))

  if (Sigma_ok) {
    subject_pars <- emc_make_random_effects(
      design      = design_obj,
      group_means = group_params$mu,
      n_subj      = NULL,
      covariances = group_params$Sigma
    )
  } else {
    warning("Using variance_proportion = 0.2 fallback (Sigma not positive-definite).")
    subject_pars <- emc_make_random_effects(
      design             = design_obj,
      group_means        = group_params$mu,
      n_subj             = NULL,
      variance_proportion = 0.2
    )
  }

  # Simulate data using the real trial structure as template.
  # make_data() returns FALSE (not a data frame) when >10% of parameter values
  # fall outside model bounds; stop early with a clear message in that case.
  sim_data <- emc_make_data(subject_pars, design_obj, data = template_data)
  if (isFALSE(sim_data)) {
    stop(
      "make_data() returned FALSE: >10% of drawn subject parameters fall ",
      "outside model bounds. This typically means the group-level Sigma is ",
      "too diffuse. Check Sigma eigenvalues from extract_group_params()."
    )
  }

  truncated <- truncate_to_window(sim_data, rt_window)
  out <- list(data = truncated$data, subject_pars = subject_pars)
  if (!is.null(truncated$dropped)) out$dropped <- truncated$dropped
  out
}
