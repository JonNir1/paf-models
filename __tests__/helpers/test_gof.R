#' =============================================================================
#' Level-1 unit tests for R/eval/helpers/gof.R (no EMC2 or loo required):
#'   - log_lik_per_trial()   (per-trial copy of EMC2:::log_likelihood_race)
#'   - loo_summary_row()
#'   - .tidy_loo_compare()   (the pure part of make_loo_comparison_df())
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "eval", "helpers", "gof.R"))


# =============================================================================
# log_lik_per_trial()
# =============================================================================

# A dadm with n_acc accumulator rows per trial (lR varies fastest, as in EMC2),
# winner_acc[i] the responding accumulator of trial i. The mock model reads the
# density from pars[, "d"] and the CDF from pars[, "p"], so each row can carry
# its own value and the expected per-trial sum is closed form.
.mk_dadm <- function(winner_acc, n_acc, expand = seq_along(winner_acc)) {
  n_trials <- length(winner_acc)
  lR <- rep(seq_len(n_acc), n_trials)
  df <- data.frame(
    rt     = 0.4,
    R      = factor(rep(winner_acc, each = n_acc), levels = seq_len(n_acc)),
    lR     = factor(lR, levels = seq_len(n_acc)),
    winner = lR == rep(winner_acc, each = n_acc)
  )
  attr(df, "expand") <- expand
  df
}
.mk_pars <- function(d, p) cbind(d = d, p = p)
MODEL <- list(dfun = function(rt, pars) pars[, "d"],
              pfun = function(rt, pars) pars[, "p"])

test_that("log_lik_per_trial: log winner density + sum of log loser survivals, 2 and 4 accumulators", {
  dadm2 <- .mk_dadm(winner_acc = c(1, 2), n_acc = 2)
  pars2 <- .mk_pars(d = c(0.5, 0.9, 0.9, 0.4), p = c(0.9, 0.3, 0.2, 0.9))
  expect_equal(log_lik_per_trial(pars2, dadm2, MODEL),
               c(log(0.5) + log(1 - 0.3), log(0.4) + log(1 - 0.2)))

  # Distinct loser CDFs catch any mis-grouping of losers into trials.
  dadm4 <- .mk_dadm(winner_acc = c(2, 4), n_acc = 4)
  d4    <- c(0.9, 0.6, 0.9, 0.9,   0.9, 0.9, 0.9, 0.2)
  p4    <- c(0.1, 0.9, 0.2, 0.3,   0.4, 0.5, 0.6, 0.9)
  expect_equal(log_lik_per_trial(.mk_pars(d4, p4), dadm4, MODEL),
               c(log(0.6) + sum(log(1 - c(0.1, 0.2, 0.3))),
                 log(0.2) + sum(log(1 - c(0.4, 0.5, 0.6)))))
})

test_that("log_lik_per_trial: returns one value per expanded trial", {
  dadm <- .mk_dadm(winner_acc = c(1, 2), n_acc = 2, expand = c(1, 1, 2, 1))
  pars <- .mk_pars(d = c(0.5, 0.9, 0.9, 0.4), p = c(0.9, 0.3, 0.2, 0.9))
  ll   <- log_lik_per_trial(pars, dadm, MODEL)
  expect_false(is.matrix(ll))
  per_trial <- c(log(0.5) + log(0.7), log(0.4) + log(0.8))
  expect_equal(ll, per_trial[c(1, 1, 2, 1)])
})

test_that("log_lik_per_trial: NaN densities, not-ok rows and out-of-race accumulators clamp to min_ll", {
  min_ll <- log(1e-10)
  dadm   <- .mk_dadm(winner_acc = c(1, 1, 1), n_acc = 2)
  good   <- log(0.5) + log(0.7)

  nan_pars <- .mk_pars(d = c(-1, 0.9, 0.5, 0.9, 0.5, 0.9), p = 0.3)
  expect_warning(ll <- log_lik_per_trial(nan_pars, dadm, MODEL, min_ll), "NaN")
  expect_equal(ll, c(min_ll, good, good))

  ok_pars <- .mk_pars(d = 0.5, p = rep(0.3, 6))
  attr(ok_pars, "ok") <- c(TRUE, TRUE, TRUE, FALSE, TRUE, TRUE)
  expect_equal(log_lik_per_trial(ok_pars, dadm, MODEL, min_ll), c(good, min_ll, good))

  race <- dadm
  race$RACE <- factor(c(2, 2, 1, 1, 2, 2))   # trial 2 races only accumulator 1
  expect_equal(log_lik_per_trial(.mk_pars(d = 0.5, p = rep(0.3, 6)), race, MODEL, min_ll),
               c(good, min_ll, good))
})


# =============================================================================
# loo_summary_row()
# =============================================================================

.mk_loo <- function(pareto_k = c(0.1, 0.2, 0.8)) {
  list(
    estimates = matrix(
      c(-50, 5, 100,   # Estimate: elpd_loo, p_loo, looic
          2, 1,  10),  # SE
      nrow = 3, dimnames = list(c("elpd_loo", "p_loo", "looic"), c("Estimate", "SE"))
    ),
    diagnostics = list(pareto_k = pareto_k)
  )
}
.mk_waic <- function() {
  list(estimates = matrix(
    c(-51, 2.1, 102,   # Estimate: elpd_waic, p_waic, waic
      5.2, 1.1,  11),  # SE
    nrow = 3, dimnames = list(c("elpd_waic", "p_waic", "waic"), c("Estimate", "SE"))
  ))
}

test_that("loo_summary_row: one row with every column, values read from the estimate matrices", {
  row <- loo_summary_row("model1", .mk_loo(), .mk_waic())
  expect_equal(nrow(row), 1)
  expect_setequal(names(row), c("model", "elpd_loo", "se_elpd_loo", "p_loo", "looic",
                                "elpd_waic", "se_elpd_waic", "p_waic", "waic",
                                "k_frac_bad", "k_flag"))
  expect_equal(unlist(row[c("elpd_loo", "se_elpd_loo", "p_loo", "looic")]),
               c(elpd_loo = -50, se_elpd_loo = 2, p_loo = 5, looic = 100))
  expect_equal(unlist(row[c("elpd_waic", "se_elpd_waic", "p_waic", "waic")]),
               c(elpd_waic = -51, se_elpd_waic = 5.2, p_waic = 2.1, waic = 102))
  expect_equal(row$model, "model1")
})

test_that("loo_summary_row: k_flag needs a bad-k fraction strictly above the cutoff", {
  cases <- list(
    list(k = rep(0.3, 20),               frac = 0,   flag = FALSE),
    list(k = c(rep(0.1, 9), 0.8),        frac = 0.1, flag = FALSE),   # exactly at 10%
    list(k = c(rep(0.1, 9), 0.7),        frac = 0,   flag = FALSE),   # k == threshold is not bad
    list(k = c(rep(0.1, 8), 0.8, 0.9),   frac = 0.2, flag = TRUE)
  )
  for (cs in cases) {
    row <- loo_summary_row("m", .mk_loo(cs$k), .mk_waic(),
                           pareto_k_threshold = 0.7, pareto_k_bad_frac = 0.10)
    expect_equal(row$k_frac_bad, cs$frac, label = deparse(cs$k))
    expect_identical(row$k_flag, cs$flag, label = deparse(cs$k))
  }
})


# =============================================================================
# .tidy_loo_compare()
# =============================================================================

test_that(".tidy_loo_compare: keeps loo_compare's row order as a model column", {
  comp <- cbind(elpd_diff = c(0, -3, -8), se_diff = c(0, 1.5, 2.3),
                elpd_loo = c(-50, -53, -58))
  rownames(comp) <- c("m2", "m1", "m3")
  df <- .tidy_loo_compare(comp)
  expect_equal(names(df), c("model", "elpd_diff", "se_diff"))
  expect_equal(df$model, c("m2", "m1", "m3"))
  expect_equal(df$elpd_diff, c(0, -3, -8))
  expect_equal(df$se_diff, c(0, 1.5, 2.3))
  expect_equal(rownames(df), c("1", "2", "3"))
})
