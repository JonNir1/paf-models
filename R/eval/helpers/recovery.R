#' =========================
#' Parameter-Recovery Evaluation Helpers (step 2.5 / 2.9)
#' =========================
#' Pure, testable computations behind the recovery analysis. Distinct from the
#' fit-side R/fit/helpers/recovery.R (which *generates* recovery data); this file
#' *evaluates* recovery fits.
#'
#'   get_prior_sds()           -- prior SDs from a fitted model's stored prior
#'   mu_posterior()            -- posterior mean & SD of the $mu block
#'   recovery_population_rows() -- true vs estimated mu per parameter
#'   recovery_zscore_rows()    -- posterior z-score + contraction (Schad 2021)
#'   recovery_subject_rows()   -- subject-level estimated vs true alpha (long)
#'   recovery_subject_stats()  -- per-model RMSE + Pearson r at the alpha level
#'
#' "True" group mu = the data-generating value, recovered from the ORIGINAL
#' extended fit via extract_group_params() (R/fit/helpers/recovery.R).
#'
#' Source chain: recovery.R (eval) -> utils.R. EMC2 loaded by the caller.

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))


#' Prior SDs for the population means, from a fitted model's stored prior.
#'
#' The "standard" EMC2 prior stores the population-mean prior covariance in
#' `model[[1]]$prior$theta_mu_var`; its diagonal is the per-parameter prior
#' variance. Verified against EMC2 3.4.1. Replaces the old hardcoded name->SD map.
#'
#' @param model A fitted EMC2 model (emc object).
#' @return Named numeric vector of prior SDs.
get_prior_sds <- function(model) {
  pr <- model[[1]]$prior
  if (is.null(pr) || is.null(pr$theta_mu_var)) {
    stop("Could not find prior$theta_mu_var on the model; unexpected EMC2 prior layout.")
  }
  sqrt(diag(pr$theta_mu_var))
}


#' Posterior mean and SD of the population-mean ($mu) block.
#'
#' @param fit A fitted EMC2 model.
#' @return list(mean = <named numeric>, sd = <named numeric>).
mu_posterior <- function(fit) {
  library(EMC2)
  samples <- get_pars(fit, selection = "mu", stage = "sample",
                      map = FALSE, return_mcmc = TRUE)
  mat <- do.call(rbind, lapply(samples, as.matrix))   # (n_samples x n_pars), named cols
  list(mean = colMeans(mat), sd = apply(mat, 2, stats::sd))
}


#' True vs estimated population means, one row per parameter.
#'
#' @param fit        Recovery fit (refit on simulated data).
#' @param mu_true    Named numeric vector of data-generating mu (from the
#'                   original extended fit via extract_group_params()$mu).
#' @param model_name,sim Labels.
#' @return data.frame(model, sim, parameter, mu_true, mu_est, mu_sd).
recovery_population_rows <- function(fit, mu_true, model_name, sim) {
  mp     <- mu_posterior(fit)
  common <- intersect(names(mu_true), names(mp$mean))
  data.frame(
    model     = model_name,
    sim       = sim,
    parameter = common,
    mu_true   = as.numeric(mu_true[common]),
    mu_est    = as.numeric(mp$mean[common]),
    mu_sd     = as.numeric(mp$sd[common]),
    stringsAsFactors = FALSE
  )
}


#' Posterior z-score and contraction (Schad, Betancourt & Vasishth 2021). Pure.
#'
#'   z           = (mu_est - mu_true) / SD_post
#'   contraction = 1 - var_post / var_prior
#'
#' Vectorised over parameters. `prior_sd` may contain NA (-> NA contraction).
#'
#' @return list(z_score = <numeric>, contraction = <numeric>).
zscore_contraction <- function(mu_est, mu_true, post_sd, prior_sd) {
  list(
    z_score     = (mu_est - mu_true) / post_sd,
    contraction = 1 - (post_sd^2) / (prior_sd^2)
  )
}


#' Posterior z-score and contraction per parameter (Schad et al. 2021).
#'
#' @param fit        Recovery fit.
#' @param mu_true    Data-generating mu (named).
#' @param prior_sds  Named prior SDs (from get_prior_sds()).
#' @param model_name,sim Labels.
#' @return data.frame(model, sim, parameter, mu_true, mu_est, mu_sd, z_score, contraction).
recovery_zscore_rows <- function(fit, mu_true, prior_sds, model_name, sim) {
  mp     <- mu_posterior(fit)
  common <- intersect(names(mu_true), names(mp$mean))

  est    <- as.numeric(mp$mean[common])
  tru    <- as.numeric(mu_true[common])
  post_sd <- as.numeric(mp$sd[common])
  pri_sd  <- as.numeric(prior_sds[common])                # NA where prior SD unknown
  zc      <- zscore_contraction(est, tru, post_sd, pri_sd)

  data.frame(
    model       = model_name,
    sim         = sim,
    parameter   = common,
    mu_true     = tru,
    mu_est      = est,
    mu_sd       = post_sd,
    z_score     = zc$z_score,
    contraction = zc$contraction,
    stringsAsFactors = FALSE
  )
}


#' Posterior mean of each subject's parameters (alpha block).
#'
#' get_pars(selection="alpha", return_mcmc=TRUE) is PARAMETER-keyed: a list of
#' length n_pars, each element a [samples x subjects] matrix (subjects = columns).
#' Verified against EMC2 3.4.1. We take the posterior mean over samples for each
#' subject, returning a subjects x parameters matrix.
#'
#' @param fit A fitted EMC2 model.
#' @return matrix (subjects x parameters); rownames = subject ids, colnames = params.
alpha_posterior_means <- function(fit) {
  library(EMC2)
  per_par <- get_pars(fit, selection = "alpha", stage = "sample",
                      map = FALSE, return_mcmc = TRUE)
  # colMeans of each [samples x subjects] -> named vector over subjects;
  # sapply binds one column per parameter -> subjects x parameters.
  sapply(per_par, function(ch) colMeans(as.matrix(ch)))
}


#' Long-format subject-level recovery points: estimated vs true alpha.
#'
#' Aligns estimated posterior means with the true (data-generating) subject
#' parameters by subject id and parameter name (defensive: name-based, not
#' positional).
#'
#' @param fit         Recovery fit (refit on simulated data).
#' @param true_alpha  Matrix (subjects x parameters) from make_random_effects().
#' @param model_name,sim Labels.
#' @return data.frame(model, sim, parameter, subject, true, est).
recovery_subject_rows <- function(fit, true_alpha, model_name, sim) {
  est_mat <- alpha_posterior_means(fit)

  subj <- intersect(rownames(true_alpha), rownames(est_mat))
  pars <- intersect(colnames(true_alpha), colnames(est_mat))
  if (length(subj) == 0L || length(pars) == 0L) {
    stop("recovery_subject_rows: no overlapping subjects/parameters between ",
         "true_alpha and the fit's alpha estimates.")
  }

  do.call(rbind, lapply(pars, function(p) {
    data.frame(
      model     = model_name,
      sim       = sim,
      parameter = p,
      subject   = subj,
      true      = as.numeric(true_alpha[subj, p]),
      est       = as.numeric(est_mat[subj, p]),
      stringsAsFactors = FALSE
    )
  }))
}


#' Per-(model, parameter) recovery statistics from subject points: RMSE + r.
#'
#' @param points_df Output of recovery_subject_rows() (may stack multiple sims).
#' @return data.frame(model, parameter, n, rmse, r), pooled across sims/subjects.
recovery_subject_stats <- function(points_df) {
  grp <- split(points_df, list(points_df$model, points_df$parameter), drop = TRUE)
  do.call(rbind, lapply(grp, function(d) {
    data.frame(
      model     = d$model[1],
      parameter = d$parameter[1],
      n         = nrow(d),
      rmse      = sqrt(mean((d$est - d$true)^2)),
      r         = suppressWarnings(stats::cor(d$est, d$true)),
      stringsAsFactors = FALSE
    )
  }))
}


#' Flag whether a parameter is in the identifiable "core" subspace.
#'
#' FALSE for the StimulusAtLoc x SearchDifficulty partially-nested block (see
#' STRUCTURAL_UNIDENTIFIABLE_PATTERN in eval_config.R). Pure / vectorised.
#'
#' @param parameter Character vector of parameter names.
#' @param pattern   Regex for the structurally-unidentifiable block.
#' @return Logical vector (TRUE = identifiable core).
flag_identifiable <- function(parameter, pattern = STRUCTURAL_UNIDENTIFIABLE_PATTERN) {
  !grepl(pattern, parameter)
}


#' Per-model recovery summary over the FULL set and the identifiable CORE subspace.
#'
#' @param subj_stats Output of recovery_subject_stats() (one row per model x param).
#' @param pattern    Structural-unidentifiability regex.
#' @return data.frame(model, n_all, rmse_all, r_all, n_core, rmse_core, r_core).
recovery_model_summary <- function(subj_stats, pattern = STRUCTURAL_UNIDENTIFIABLE_PATTERN) {
  subj_stats$identifiable <- flag_identifiable(subj_stats$parameter, pattern)
  do.call(rbind, lapply(split(subj_stats, subj_stats$model), function(d) {
    core <- d[d$identifiable, ]
    data.frame(
      model     = d$model[1],
      n_all     = nrow(d),    rmse_all  = mean(d$rmse),    r_all  = mean(d$r),
      n_core    = nrow(core), rmse_core = mean(core$rmse), r_core = mean(core$r),
      stringsAsFactors = FALSE
    )
  }))
}
