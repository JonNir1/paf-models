#' =============================================================================
#' Level-1 unit tests for R/eval/helpers/gof.R (no EMC2 or loo required):
#'   - log_lik_per_trial()
#'   - loo_summary_row()
#'   - make_loo_comparison_df() via comparison_matrix_to_df() logic
#' =============================================================================

.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "eval", "helpers", "gof.R"))


# =============================================================================
# Shared mock constructors
# =============================================================================

# Build a minimal 2-accumulator dadm for n_trials trials.
# Row layout: [winner_acc, loser_acc] repeated n_trials times.
.mk_dadm <- function(n_trials = 3, rt = 0.4) {
  n_acc  <- 2
  n_rows <- n_acc * n_trials
  df <- data.frame(
    rt     = rep(rt, n_rows),
    R      = factor(rep(c("1", "2"), n_trials)),
    lR     = factor(rep(c("1", "2"), n_trials)),
    winner = rep(c(TRUE, FALSE), n_trials),
    stringsAsFactors = FALSE
  )
  attr(df, "expand") <- seq_len(n_trials)
  df
}

# Minimal model_obj: density always 0.5, survival always 0.3.
.mk_model <- function() {
  list(
    dfun = function(rt, pars) rep(0.5, length(rt)),
    pfun = function(rt, pars) rep(0.3, length(rt))
  )
}

# Parameter matrix matching nrow(dadm).
.mk_pars <- function(n_rows, n_pars = 3) {
  matrix(1.0, nrow = n_rows, ncol = n_pars)
}

# Minimal loo object with the structure loo_summary_row() reads.
.mk_loo <- function(pareto_k = c(0.1, 0.2, 0.8)) {
  # matrix() fills column-by-column: Estimate col first, then SE col
  list(
    estimates = matrix(
      c(-50, 5, 100,   # Estimate: elpd_loo, p_loo, looic
          2, 1,  10),  # SE:       elpd_loo, p_loo, looic
      nrow = 3, ncol = 2,
      dimnames = list(c("elpd_loo", "p_loo", "looic"), c("Estimate", "SE"))
    ),
    diagnostics = list(pareto_k = pareto_k)
  )
}

.mk_waic <- function() {
  list(
    estimates = matrix(
      c(-51, 2.1, 5.2, 1.1, 102, 11),
      nrow = 3, ncol = 2,
      dimnames = list(c("elpd_waic", "p_waic", "waic"), c("Estimate", "SE"))
    )
  )
}


# =============================================================================
# log_lik_per_trial()
# =============================================================================

test_that("log_lik_per_trial returns a vector, not a scalar", {
  dadm <- .mk_dadm(3)
  pars <- .mk_pars(nrow(dadm))
  ll   <- log_lik_per_trial(pars, dadm, .mk_model())
  expect_true(is.numeric(ll))
  expect_false(is.matrix(ll))
  expect_equal(length(ll), 3)
})

test_that("log_lik_per_trial length equals number of trials (expand attribute)", {
  for (n in c(1, 5, 10)) {
    dadm <- .mk_dadm(n)
    ll   <- log_lik_per_trial(.mk_pars(nrow(dadm)), dadm, .mk_model())
    expect_equal(length(ll), n, info = paste("n_trials =", n))
  }
})

test_that("log_lik_per_trial values are all <= 0", {
  dadm <- .mk_dadm(4)
  ll   <- log_lik_per_trial(.mk_pars(nrow(dadm)), dadm, .mk_model())
  expect_true(all(ll <= 0))
})

test_that("log_lik_per_trial clamps NaN/NA from bad densities to min_ll", {
  dadm       <- .mk_dadm(2)
  bad_model  <- list(
    dfun = function(rt, pars) c(-1, 0),   # -1 triggers log(-1) = NaN
    pfun = function(rt, pars) rep(0.3, length(rt))
  )
  pars <- .mk_pars(nrow(dadm))
  ll   <- log_lik_per_trial(pars, dadm, bad_model, min_ll = log(1e-10))
  expect_true(all(is.finite(ll)))
  expect_true(all(ll >= log(1e-10)))
})


# =============================================================================
# loo_summary_row()
# =============================================================================

test_that("loo_summary_row returns a 1-row data.frame with all expected columns", {
  row <- loo_summary_row("model1", .mk_loo(), .mk_waic())
  expect_equal(nrow(row), 1)
  expected_cols <- c("model", "elpd_loo", "se_elpd_loo", "p_loo", "looic",
                     "elpd_waic", "se_elpd_waic", "p_waic", "waic",
                     "k_frac_bad", "k_flag")
  expect_true(all(expected_cols %in% names(row)))
  expect_equal(row$model, "model1")
})

test_that("k_flag is FALSE when k_frac_bad <= pareto_k_bad_frac", {
  # 1/10 = 10% exactly at threshold -> NOT flagged (strict >)
  loo_10pct <- .mk_loo(pareto_k = c(rep(0.1, 9), 0.8))
  row <- loo_summary_row("m", loo_10pct, .mk_waic(),
                          pareto_k_threshold = 0.7, pareto_k_bad_frac = 0.10)
  expect_false(row$k_flag)
  expect_equal(row$k_frac_bad, 0.1)
})

test_that("k_flag is TRUE when k_frac_bad > pareto_k_bad_frac", {
  # 2/10 = 20% > 10% -> flagged
  loo_20pct <- .mk_loo(pareto_k = c(rep(0.1, 8), 0.8, 0.9))
  row <- loo_summary_row("m", loo_20pct, .mk_waic(),
                          pareto_k_threshold = 0.7, pareto_k_bad_frac = 0.10)
  expect_true(row$k_flag)
  expect_equal(row$k_frac_bad, 0.2)
})

test_that("k_flag is FALSE when no bad k values", {
  loo_clean <- .mk_loo(pareto_k = rep(0.3, 20))
  row <- loo_summary_row("m", loo_clean, .mk_waic())
  expect_false(row$k_flag)
  expect_equal(row$k_frac_bad, 0)
})

test_that("loo_summary_row extracts correct elpd_loo from estimates matrix", {
  row <- loo_summary_row("m", .mk_loo(), .mk_waic())
  expect_equal(row$elpd_loo, -50)
  expect_equal(row$se_elpd_loo, 2)
  expect_equal(row$looic, 100)
})


# =============================================================================
# make_loo_comparison_df() -- test the underlying tidy logic via a mock matrix
# (loo::loo_compare() itself is not called at L1)
# =============================================================================

# Replicate what make_loo_comparison_df does, but driven from a raw matrix so
# the loo package is not required.
.comparison_matrix_to_df <- function(comp_mat) {
  df <- as.data.frame(comp_mat[, c("elpd_diff", "se_diff"), drop = FALSE])
  df$model <- rownames(comp_mat)
  rownames(df) <- NULL
  df[, c("model", "elpd_diff", "se_diff")]
}

test_that("comparison_matrix_to_df: reference model has elpd_diff = 0", {
  mat <- matrix(
    c(0, 0, -5.2, 2.1),
    nrow = 2, ncol = 2,
    dimnames = list(c("model1", "model2"), c("elpd_diff", "se_diff"))
  )
  df <- .comparison_matrix_to_df(mat)
  expect_equal(df$elpd_diff[df$model == "model1"], 0)
})

test_that("comparison_matrix_to_df has exactly columns model, elpd_diff, se_diff", {
  mat <- matrix(
    c(0, 0, -3, 1.5, -8, 2.3),
    nrow = 3, ncol = 2,
    dimnames = list(c("m1", "m2", "m3"), c("elpd_diff", "se_diff"))
  )
  df <- .comparison_matrix_to_df(mat)
  expect_equal(names(df), c("model", "elpd_diff", "se_diff"))
  expect_equal(nrow(df), 3)
})
