#' =============================================================================
#' Goodness-of-Fit helpers: per-trial log-likelihood extraction, LOO / WAIC.
#'
#' EMC2 has no exported log_lik_matrix() function.  We work around this by
#' reaching into unexported internals:
#'
#'   log_lik_per_trial()      -- copy of EMC2:::log_likelihood_race with the
#'                               final sum() removed so per-trial values are
#'                               returned instead of a per-subject total.
#'   extract_log_lik_matrix() -- drives the above over all posterior samples ×
#'                               subjects using the EMC2 parameter-matrix
#'                               internal (see .emc2_pars_matrix_fn()) to apply
#'                               the full parameter transform chain.
#'
#' NOTE: both functions call EMC2 unexported internals (:::).  If EMC2 changes
#' its internal API in a future release, this file must be updated.
#' A feature request for a native per-trial LL export has been filed at the
#' EMC2 GitHub (see spawned task in this Claude session).
#'
#' Source chain: gof.R -> utils.R, emc2_api.R  (callers load EMC2 + loo; no library() here)
#'
#' Public surface:
#'   log_lik_per_trial()
#'   extract_log_lik_matrix()
#'   loo_summary_row()
#'   make_loo_comparison_df()
#'   create_goodness_of_fit_table()
#'   create_loo_table()
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/helpers/emc2_api.R")       # emc_get_pars, emc_compare


#' Per-trial log-likelihood for a race (LBA) model.
#'
#' Direct adaptation of EMC2:::log_likelihood_race: the body is identical
#' except that `sum(pmax(...))` is replaced with `pmax(...)` so a per-trial
#' vector is returned instead of a scalar per-subject sum.
#'
#' @param pars      Parameter matrix `[nrow(dadm) x n_params]` on the
#'                  *transformed* scale (output of .emc2_pars_matrix_fn()).
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


#' Resolve EMC2's unexported parameter-matrix function.
#'
#' 3.5.0 renamed `get_pars_matrix` to `get_pars_matrix_oo` (same call shape:
#' `(p_vector, dadm, model)`); 3.4.1 only has the old name.
#'
#' @return The function `(p_vector, dadm, model)` -> transformed parameter matrix.
.emc2_pars_matrix_fn <- function() {
  ns <- asNamespace("EMC2")
  for (fn_name in c("get_pars_matrix_oo", "get_pars_matrix")) {
    if (exists(fn_name, envir = ns, inherits = FALSE)) return(get(fn_name, envir = ns))
  }
  stop("EMC2 exposes neither get_pars_matrix_oo nor get_pars_matrix; update .emc2_pars_matrix_fn().")
}


#' Per-subject trial counts of a fitted model, named by subject.
.trial_counts <- function(fitted_model) {
  vapply(fitted_model[[1]]$data, function(d) length(attr(d, "expand")), integer(1))
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
#' @param max_samples   Keep at most this many posterior samples in total (avoids
#'                      very large matrices; default 2000), as floor(max_samples /
#'                      n_chains) evenly spaced draws WITHIN each chain (all draws
#'                      when a chain has fewer), so every chain contributes equally.
#' @param cores         Passed to `parallel::mclapply` over subjects.
#'                      On Windows falls back to serial (no fork support).
#' @return Numeric matrix `[n_samples x n_trials_total]`; columns run over
#'         trials concatenated in the order subjects are stored in
#'         `fitted_model[[1]]$data`. Attribute `chain_id` (integer, one per row)
#'         gives each retained draw's chain, for loo::relative_eff().
extract_log_lik_matrix <- function(fitted_model, max_samples = 2000L, cores = 1L) {
  get_pars_matrix <- .emc2_pars_matrix_fn()

  model_factory <- fitted_model[[1]][["model"]]
  model_obj     <- model_factory()
  data_list     <- fitted_model[[1]]$data
  n_subj        <- length(data_list)

  # Alpha samples: get_pars returns list[par_name] of mcmc.list objects.
  # Collapse chains via as.matrix() -> list[par_name][total_samples x n_subj].
  alpha_raw <- emc_get_pars(fitted_model, selection = "alpha", stage = "sample", map = FALSE,
                            return_mcmc = TRUE)
  alpha     <- lapply(alpha_raw, as.matrix)
  chain_n   <- vapply(alpha_raw[[1]], nrow, integer(1))
  if (length(unique(chain_n)) != 1L)
    stop("Chains of the alpha draws do not have equal numbers of samples.")
  n_chains    <- length(chain_n)
  n_per_chain <- chain_n[[1]]

  subj_names <- names(data_list)
  if (is.null(subj_names) || !setequal(subj_names, colnames(alpha[[1]])))
    stop("Subject names of the model data and of the alpha draws do not match.")

  keep_per_chain <- max(1L, max_samples %/% n_chains)
  within_idx <- if (n_per_chain > keep_per_chain) {
    round(seq(1, n_per_chain, length.out = keep_per_chain))
  } else {
    seq_len(n_per_chain)
  }
  s_idx     <- as.vector(outer(within_idx, (seq_len(n_chains) - 1L) * n_per_chain, `+`))
  chain_id  <- rep(seq_len(n_chains), each = length(within_idx))
  n_samples <- length(s_idx)

  n_trials_per_subj <- .trial_counts(fitted_model)
  n_trials_total    <- sum(n_trials_per_subj)
  col_ends          <- cumsum(n_trials_per_subj)
  col_starts        <- col_ends - n_trials_per_subj + 1L

  ll_matrix <- matrix(NA_real_, nrow = n_samples, ncol = n_trials_total)

  subj_blocks <- parallel::mclapply(seq_len(n_subj), function(s) {
    dadm_s <- data_list[[s]]
    n_t    <- n_trials_per_subj[s]
    block  <- matrix(NA_real_, nrow = n_samples, ncol = n_t)
    for (ii in seq_len(n_samples)) {
      p_vec        <- vapply(alpha, `[`, numeric(1), s_idx[ii], subj_names[s])
      pars_mat     <- get_pars_matrix(p_vec, dadm_s, model_obj)
      block[ii, ] <- log_lik_per_trial(pars_mat, dadm_s, model_obj)
    }
    block
  }, mc.cores = cores)

  for (s in seq_len(n_subj)) {
    ll_matrix[, col_starts[s]:col_ends[s]] <- subj_blocks[[s]]
  }

  attr(ll_matrix, "chain_id") <- chain_id
  ll_matrix
}


#' Relative MCMC efficiency of each trial's likelihood, for loo::loo(r_eff=).
#'
#' loo::relative_eff() takes likelihood values and needs the same number of
#' draws per chain. ESS is scale-invariant, so each column is scaled by its
#' maximum before exp() to avoid underflow of very negative log-likelihoods.
#'
#' @param ll_mat Matrix from extract_log_lik_matrix() (with `chain_id` attribute).
#' @param cores  Passed to loo::relative_eff().
#' @return Numeric vector, one value per trial.
trial_relative_eff <- function(ll_mat, cores = 1L) {
  chain_id <- attr(ll_mat, "chain_id")
  if (is.null(chain_id)) stop("ll_mat has no 'chain_id' attribute.")
  col_max <- apply(ll_mat, 2, max)
  lik     <- exp(sweep(ll_mat, 2, col_max))
  loo::relative_eff(lik, chain_id = chain_id, cores = cores)
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
#' elpd_diff = 0. Stops unless all models cover the same trials: equal total
#' counts AND identical `trial_counts` attributes (named per-subject counts,
#' attached by create_loo_table()), i.e. same subjects in the same order.
#'
#' @param loo_list  Named list of loo objects (one per model).
#' @return data.frame, columns: model, elpd_diff, se_diff.
make_loo_comparison_df <- function(loo_list) {
  n_obs <- vapply(loo_list, function(x) nrow(x$pointwise), integer(1))
  if (length(unique(n_obs)) > 1L)
    stop(sprintf("Models cover different numbers of trials (%s); LOO comparison is invalid.",
                 paste(names(n_obs), n_obs, sep = "=", collapse = ", ")))
  counts <- lapply(loo_list, attr, "trial_counts")
  if (any(vapply(counts, is.null, logical(1))))
    stop("A loo object carries no 'trial_counts' attribute (created by create_loo_table()); ",
         "recompute the LOO table before comparing.")
  if (!all(vapply(counts, identical, logical(1), counts[[1]])))
    stop("Models differ in subjects (or their order) or per-subject trial counts; ",
         "LOO comparison is invalid.")
  .tidy_loo_compare(loo::loo_compare(loo_list))
}


#' Tidy a `loo::loo_compare()` matrix into a data.frame. Pure.
#'
#' @param comp_mat Matrix with rownames = models, columns incl. elpd_diff, se_diff.
#' @return data.frame, columns: model, elpd_diff, se_diff.
.tidy_loo_compare <- function(comp_mat) {
  df <- as.data.frame(comp_mat[, c("elpd_diff", "se_diff"), drop = FALSE])
  df$model <- rownames(comp_mat)
  rownames(df) <- NULL
  df[, c("model", "elpd_diff", "se_diff")]
}


#' DIC / BPIC comparison table via EMC2::compare(), for both IC types.
#'
#' Fast (no LL matrix needed). `compare()` is run with type = "conditional"
#' (data likelihood only) and type = "joint" (adds the group-level density);
#' `type` is always passed explicitly. DIC is reported only; BPIC is for
#' screening. No Bayes Factors (excluded from the analysis plan: priors not
#' grounded enough), so `BayesFactor = FALSE` always.
#'
#' EMC2 3.5.0 compare() reuses `attr(x, "ICs")` (set by add_ICs_MLL()) whenever
#' it is present on a model object, whatever `type` is requested; both
#' attributes ("ICs", "MLL") are therefore stripped from local copies first.
#'
#' `mean_LL_<type>` is `meanD_<type> / -2`. For type = "conditional" this is the
#' mean data log-likelihood. For type = "joint", meanD includes the group-level
#' (hierarchical) density, so `mean_LL_joint` is NOT a data log-likelihood; it
#' is kept as the historical `mean_LL` definition only.
#'
#' @param model_list Named list of fitted EMC2 model objects.
#' @param verbose    Logical; if TRUE, print compare()'s own summary.
#' @return data.frame, one row per model: model, num_params, then each IC column
#'   twice with suffix `_conditional` / `_joint`.
create_goodness_of_fit_table <- function(model_list, verbose = FALSE) {
  ic_cols <- c("EffectiveN", "DIC", "wDIC", "BPIC", "wBPIC",
               "mean_LL", "meanD", "Dmean", "minD")

  fresh_list <- lapply(model_list, function(m) {
    attr(m, "ICs") <- NULL
    attr(m, "MLL") <- NULL
    m
  })

  per_type <- lapply(c("conditional", "joint"), function(ic_type) {
    comp_df <- as.data.frame(emc_compare(
      fresh_list,
      type          = ic_type,
      print_summary = verbose,
      BayesFactor   = FALSE
    ))
    comp_df$mean_LL <- comp_df$meanD / -2   # joint: meanD includes the group-level density
    out <- comp_df[, ic_cols, drop = FALSE]
    names(out) <- paste0(ic_cols, "_", ic_type)
    out
  })

  data.frame(
    model      = names(model_list),
    num_params = sapply(model_list, function(m) m[[1]][["n_pars"]]),
    per_type[[1]], per_type[[2]],
    row.names = NULL, check.names = FALSE
  )
}


#' LOO / WAIC summary table for a list of fitted models.
#'
#' Calls extract_log_lik_matrix() + loo::loo() (with r_eff from the chain
#' structure) + loo::waic() per model.
#' Caches per-model loo objects to LOO_DIR/<model_name>_loo.rds for use by
#' make_loo_comparison_df() and plot_pareto_k(). Each loo object carries the
#' model's per-subject trial counts as attribute "trial_counts"; models with
#' different trial structures still get their own rows (only the comparison
#' is invalid, and make_loo_comparison_df() rejects it).
#'
#' LOO_DIR, PARETO_K_THRESHOLD, and PARETO_K_BAD_FRAC must be in scope
#' (provided by eval_config.R via the caller).
#'
#' @param model_list  Named list of fitted EMC2 model objects.
#' @param max_samples Keep at most this many posterior samples, evenly strided
#'                    within each chain (default 2000).
#' @param cores       Parallelism over subjects; on Windows falls back to serial.
#' @return data.frame, one row per model (columns from loo_summary_row()).
create_loo_table <- function(model_list, max_samples = 2000L, cores = 1L) {
  dir.create(LOO_DIR, recursive = TRUE, showWarnings = FALSE)
  rows <- lapply(names(model_list), function(mname) {
    message(sprintf("  [LOO] extracting log-lik matrix for %s ...", mname))
    ll_mat   <- extract_log_lik_matrix(model_list[[mname]], max_samples, cores)
    message(sprintf("  [LOO] running loo::loo() for %s ...", mname))
    loo_obj  <- loo::loo(ll_mat, r_eff = trial_relative_eff(ll_mat, cores), cores = cores)
    waic_obj <- loo::waic(ll_mat)
    attr(loo_obj, "trial_counts") <- .trial_counts(model_list[[mname]])
    saveRDS(loo_obj, file.path(LOO_DIR, paste0(mname, "_loo.rds")))
    loo_summary_row(mname, loo_obj, waic_obj,
                    pareto_k_threshold = PARETO_K_THRESHOLD,
                    pareto_k_bad_frac  = PARETO_K_BAD_FRAC)
  })
  do.call(rbind, rows)
}
