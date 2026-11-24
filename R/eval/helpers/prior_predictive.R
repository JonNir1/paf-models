#' =============================================================================
#' Prior-predictive helpers (analysis2 step 0)
#'
#'   sample_prior_group_params()  -- one draw of (mu, Sigma) from a model's prior
#'   summarise_prior_predictive() -- RT / window / choice summary of one simulated dataset
#'   plot_prior_predictive()      -- per-model distribution of those summaries across draws
#'
#' A draw is EMC2 3.5.0's "standard" prior (get_prior_standard()): mu ~ N(theta_mu_mean,
#' theta_mu_var); a_k ~ InvGamma(1/2, 1/A_k^2); Sigma ~ InvWishart(df = v + n - 1,
#' scale = 2 v diag(1/a)). Each variance has the marginal InvGamma(v/2, v/a_k) and
#' the correlations follow the prior's joint dependence. The data are then simulated
#' on the real trial structure by simulate_recovery_data() (R/fit/helpers/recovery.R).
#'
#' Source chain: prior_predictive.R -> eval/helpers/ppc.R (.response_type)
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/helpers/ppc.R")


#' One draw of group-level parameters from an EMC2 "standard" prior.
#'
#' Mirrors EMC2:::get_prior_standard() (sigma draw: riwish(v + n - 1, 2 v diag(1/a)) =
#' solve(rwish(v + n - 1, solve(2 v diag(1/a))))) with stats::rWishart; a draw whose
#' Wishart matrix is numerically singular (extreme `a`) is redrawn.
#'
#' @param prior A prior object (`model[[1]]$prior`): theta_mu_mean, theta_mu_var, v,
#'   A (scalar or one per parameter).
#' @return list(mu = named numeric, Sigma = named symmetric matrix), as
#'   extract_group_params() returns.
sample_prior_group_params <- function(prior) {
  mu_mean <- prior$theta_mu_mean
  n  <- length(mu_mean)
  mu <- stats::setNames(stats::rnorm(n, mu_mean, sqrt(diag(prior$theta_mu_var))), names(mu_mean))
  Sigma <- NULL
  for (attempt in 1:10) {
    a_half <- 1 / stats::rgamma(n, shape = 1 / 2, rate = 1 / prior$A^2)
    Sigma  <- tryCatch(solve(stats::rWishart(1, prior$v + n - 1, diag(a_half / (2 * prior$v), n))[, , 1]),
                       error = function(e) NULL)
    if (!is.null(Sigma)) break
  }
  if (is.null(Sigma)) stop("Could not draw a non-singular Sigma from the prior in 10 attempts", call. = FALSE)
  Sigma <- (Sigma + t(Sigma)) / 2
  dimnames(Sigma) <- list(names(mu), names(mu))
  list(mu = mu, Sigma = Sigma)
}


#' Summary of one simulated dataset (rows: trials with rt, R, S, search_difficulty).
#'
#' A trial without a finite RT (no accumulator finishes, e.g. all drifts negative)
#' counts as outside the window; quantiles and choice proportions use finite trials.
#'
#' @param sim_data Simulated data frame (untruncated RTs).
#' @param window   c(min, max) RT window in seconds (inclusive).
#' @return One-row data frame: `prop_finite`, RT quantiles of the finite trials,
#'   `prop_in_window` (of all trials), median RT inside the window, and
#'   P(target response) per search difficulty.
summarise_prior_predictive <- function(sim_data, window) {
  finite <- is.finite(sim_data$rt)
  sim    <- sim_data[finite, , drop = FALSE]
  rt     <- sim$rt
  qs <- if (length(rt)) stats::quantile(rt, c(0.05, 0.25, 0.5, 0.75, 0.95), names = FALSE) else rep(NA_real_, 5)
  names(qs) <- paste0("rt_q", c("05", "25", "50", "75", "95"))
  inside   <- rt >= window[1] & rt <= window[2]
  hit      <- .response_type(sim) == "T"
  p_target <- vapply(c(easy = "EASY", difficult = "DIFFICULT"),
                     function(d) mean(hit[as.character(sim$search_difficulty) == d]), numeric(1))
  names(p_target) <- paste0("p_target_", names(p_target))
  data.frame(prop_finite = mean(finite), t(qs), prop_in_window = sum(inside) / nrow(sim_data),
             rt_median_in_window = if (any(inside)) stats::median(rt[inside]) else NA_real_,
             t(p_target), check.names = FALSE)
}


#' Prior-predictive summaries per model across prior draws.
#'
#' @param summary_df Long table: model, draw, metric, value.
#' @param reference  Optional named numeric of observed values per metric (dashed lines).
#' @return A ggplot (one panel per metric, one box per model).
plot_prior_predictive <- function(summary_df, reference = NULL) {
  library(ggplot2)
  p <- ggplot(summary_df, aes(value, model)) +
    geom_boxplot(outlier.shape = NA, fill = "grey90") +
    geom_jitter(height = 0.15, alpha = 0.5, size = 1, color = "#2c7fb8") +
    facet_wrap(~metric, scales = "free_x") +
    labs(x = NULL, y = NULL, title = "Prior predictive check",
         subtitle = "One point per prior draw; dashed line = observed value") +
    theme_bw(base_size = 11)
  if (!is.null(reference))
    p <- p + geom_vline(data = data.frame(metric = names(reference), value = unname(reference)),
                        aes(xintercept = value), linetype = "dashed")
  p
}
