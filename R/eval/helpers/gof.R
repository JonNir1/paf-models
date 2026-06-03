#' =============================================================================
#' Goodness-of-Fit helpers: per-trial log-likelihood extraction, LOO / WAIC.
#'
#' EMC2 3.4.1 has no exported log_lik_matrix() function.  We work around this
#' by reaching into unexported internals:
#'
#'   log_lik_per_trial()      -- copy of EMC2:::log_likelihood_race with the
#'                               final sum() removed so per-trial values are
#'                               returned instead of a per-subject total.
#'   extract_log_lik_matrix() -- drives the above over all posterior samples ×
#'                               subjects using EMC2:::get_pars_matrix to apply
#'                               the full parameter transform chain.
#'
#' NOTE: both functions call EMC2 unexported internals (:::).  If EMC2 changes
#' its internal API in a future release, this file must be updated.
#' A feature request for a native per-trial LL export has been filed at the
#' EMC2 GitHub (see spawned task in this Claude session).
#'
#' Source chain: gof.R -> utils.R  (callers load EMC2 + loo; no library() here)
#'
#' Public surface:
#'   log_lik_per_trial()
#'   extract_log_lik_matrix()
#'   loo_summary_row()
#'   make_loo_comparison_df()
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))


#' Per-trial log-likelihood for a race (LBA) model.
#'
#' Direct adaptation of EMC2:::log_likelihood_race: the body is identical
#' except that `sum(pmax(...))` is replaced with `pmax(...)` so a per-trial
#' vector is returned instead of a scalar per-subject sum.
#'
#' @param pars      Parameter matrix `[nrow(dadm) x n_params]` on the
#'                  *transformed* scale (output of EMC2:::get_pars_matrix).
#'                  Do NOT pass a raw p_vector here.
#' @param dadm      Augmented design matrix for ONE subject. Must contain
#'                  columns: `winner` (logical), `rt` (numeric), `R` (factor),
#'                  `lR` (factor), and attribute `"expand"` (integer indices
#'                  mapping winner rows back to the trial set).
#' @param model_obj Model object (returned by `model_factory()`); must expose
#'                  `$dfun` (density) and `$pfun` (survival function).
#' @param min_ll    Log-likelihood floor (matches EMC2 internal default).
#' @return Numeric vector of length `length(attr(dadm, "expand"))`: one
#'         per-trial log-likelihood, clamped to `min_ll` from below.
log_lik_per_trial <- function(pars, dadm, model_obj, min_ll = log(1e-10)) {
  if (any(names(dadm) == "RACE")) {
    pars[as.numeric(dadm$lR) > as.numeric(as.character(dadm$RACE)), ] <- NA
  }
  ok <- if (is.null(attr(pars, "ok"))) !logical(dim(pars)[1]) else attr(pars, "ok")

  lds <- numeric(dim(dadm)[1])
  lds[dadm$winner] <- log(
    model_obj$dfun(rt = dadm$rt[dadm$winner], pars = pars[dadm$winner, , drop = FALSE])
  )
  n_acc <- length(levels(dadm$R))
  if (n_acc > 1) {
    lds[!dadm$winner] <- log(1 - model_obj$pfun(
      rt = dadm$rt[!dadm$winner], pars = pars[!dadm$winner, , drop = FALSE]
    ))
  }
  lds[is.na(lds) | !ok] <- min_ll

  if (n_acc > 1) {
    ll <- lds[dadm$winner]
    if (n_acc == 2) {
      ll <- ll + lds[!dadm$winner]
    } else {
      ll <- ll + apply(matrix(lds[!dadm$winner], nrow = n_acc - 1), 2, sum)
    }
    ll[is.na(ll)] <- min_ll
    pmax(min_ll, ll[attr(dadm, "expand")])
  } else {
    pmax(min_ll, lds[attr(dadm, "expand")])
  }
}


#' Build the [samples x trials] log-likelihood matrix from a fitted EMC2 model.
#'
#' For each posterior sample i and trial n, evaluates
#' log p(y_n | alpha_{s(n), i}) where alpha_{s(n), i} are the subject-level
#' parameters for subject s(n) at sample i.  This is the conditional LOO
#' formulation (conditioning on the hierarchical structure), which is standard
#' practice in cognitive modelling.
#'
#' @param fitted_model  An `emc` object (output of EMC2::run_emc / load_model).
#' @param max_samples   Thin posterior samples to at most this many (avoids
#'                      very large matrices; default 2000).
#' @param cores         Passed to `parallel::mclapply` over subjects.
#'                      On Windows falls back to serial (no fork support).
#' @return Numeric matrix `[n_samples x n_trials_total]`; columns run over
#'         trials concatenated in the order subjects are stored in
#'         `fitted_model[[1]]$data`.
extract_log_lik_matrix <- function(fitted_model, max_samples = 2000L, cores = 1L) {
  get_pars_matrix <- EMC2:::get_pars_matrix  # nolint: using unexported internal

  model_factory <- fitted_model[[1]][["model"]]
  model_obj     <- model_factory()
  data_list     <- fitted_model[[1]]$data
  n_subj        <- length(data_list)

  # Alpha samples: list[par_name][n_all_samples x n_subj]
  alpha   <- get_pars(fitted_model, selection = "alpha", return_mcmc = TRUE)
  n_all   <- nrow(alpha[[1]])

  s_idx <- if (n_all > max_samples) {
    round(seq(1, n_all, length.out = max_samples))
  } else {
    seq_len(n_all)
  }
  n_samples <- length(s_idx)

  n_trials_per_subj <- vapply(data_list, function(d) length(attr(d, "expand")), integer(1))
  n_trials_total    <- sum(n_trials_per_subj)
  col_ends          <- cumsum(n_trials_per_subj)
  col_starts        <- col_ends - n_trials_per_subj + 1L

  ll_matrix <- matrix(NA_real_, nrow = n_samples, ncol = n_trials_total)

  subj_blocks <- parallel::mclapply(seq_len(n_subj), function(s) {
    dadm_s <- data_list[[s]]
    n_t    <- n_trials_per_subj[s]
    block  <- matrix(NA_real_, nrow = n_samples, ncol = n_t)
    for (ii in seq_len(n_samples)) {
      p_vec       <- sapply(alpha, `[`, s_idx[ii], s)
      pars_mat    <- get_pars_matrix(p_vec, dadm_s, model_obj)
      block[ii, ] <- log_lik_per_trial(pars_mat, dadm_s, model_obj)
    }
    block
  }, mc.cores = cores)

  for (s in seq_len(n_subj)) {
    ll_matrix[, col_starts[s]:col_ends[s]] <- subj_blocks[[s]]
  }

  ll_matrix
}


#' Summarise LOO and WAIC results for one model into a single-row data.frame.
#'
#' Thresholds are passed as arguments (not read from config) so this function
#' is testable without sourcing eval_config.R — the same pattern as
#' add_convergence_verdict().
#'
#' @param model_name          Character scalar.
#' @param loo_obj             Object returned by `loo::loo()`.
#' @param waic_obj            Object returned by `loo::waic()`.
#' @param pareto_k_threshold  k > this = "bad" (default 0.7, Vehtari et al. 2017).
#' @param pareto_k_bad_frac   Fraction of bad k above which k_flag is TRUE.
#' @return 1-row data.frame with columns:
#'   model, elpd_loo, se_elpd_loo, p_loo, looic,
#'   elpd_waic, se_elpd_waic, p_waic, waic, k_frac_bad, k_flag.
loo_summary_row <- function(model_name, loo_obj, waic_obj,
                             pareto_k_threshold = 0.7,
                             pareto_k_bad_frac  = 0.10) {
  k_frac_bad <- mean(loo_obj$diagnostics$pareto_k > pareto_k_threshold)

  data.frame(
    model        = model_name,
    elpd_loo     = loo_obj$estimates["elpd_loo",   "Estimate"],
    se_elpd_loo  = loo_obj$estimates["elpd_loo",   "SE"],
    p_loo        = loo_obj$estimates["p_loo",      "Estimate"],
    looic        = loo_obj$estimates["looic",      "Estimate"],
    elpd_waic    = waic_obj$estimates["elpd_waic", "Estimate"],
    se_elpd_waic = waic_obj$estimates["elpd_waic", "SE"],
    p_waic       = waic_obj$estimates["p_waic",    "Estimate"],
    waic         = waic_obj$estimates["waic",      "Estimate"],
    k_frac_bad   = k_frac_bad,
    k_flag       = k_frac_bad > pareto_k_bad_frac,
    stringsAsFactors = FALSE
  )
}


#' Tidy pairwise ELPD-diff table from a named list of loo objects.
#'
#' Wraps `loo::loo_compare()`.  The reference (best) model appears first with
#' elpd_diff = 0.
#'
#' @param loo_list  Named list of loo objects (one per model).
#' @return data.frame, columns: model, elpd_diff, se_diff.
make_loo_comparison_df <- function(loo_list) {
  comp_mat <- loo::loo_compare(loo_list)
  df <- as.data.frame(comp_mat[, c("elpd_diff", "se_diff"), drop = FALSE])
  df$model <- rownames(comp_mat)
  rownames(df) <- NULL
  df[, c("model", "elpd_diff", "se_diff")]
}
