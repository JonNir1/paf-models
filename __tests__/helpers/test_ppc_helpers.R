#' =============================================================================
#' Level-1 unit tests for PPC eval helpers (no EMC2 required):
#'   - compute_dist_stats()         (R/eval/helpers/ppc.R)
#'   - compute_choice_proportions() (R/eval/helpers/ppc.R)
#'   - compute_qpf_table()          (R/eval/helpers/ppc.R) [marginal + by_response]
#' =============================================================================

library(testthat)
library(dplyr)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
# eval_config.R is needed for PPC_AD_ALPHA; source directly to avoid EMC2 load
source(file.path(ROOT, "R", "eval", "eval_config.R"))
source(file.path(ROOT, "R", "eval", "helpers", "ppc.R"))


# =============================================================================
# Shared mock data helpers
# =============================================================================

QPF_COLS   <- c("model", "experiment", "cue_size", "search_difficulty",
                "quantile", "obs", "pred_median", "pred_ci_lo", "pred_ci_hi")
QUANTILES  <- c(0.10, 0.25, 0.50, 0.75, 0.90)

# Observed data: S = "T,E,E,E" and every saccade to loc 1, so response_type = "T".
.mk_obs <- function(n_subj = 3L, n_trials = 20L) {
  data.frame(
    subjects          = rep(seq_len(n_subj), each = n_trials),
    rt                = runif(n_subj * n_trials, min = 0.25, max = 0.90),
    R                 = 1L,
    S                 = "T,E,E,E",
    cue_size          = "NONE",
    search_difficulty = "EASY",
    experiment        = "exp_1",
    stringsAsFactors  = FALSE
  )
}

# S = "T,D,E,E" with n_per_type saccades each to loc 1 (T), 2 (D) and 3 (E).
.mk_obs_mixed <- function(n_subj = 3L, n_per_type = 20L) {
  obs   <- .mk_obs(n_subj, 3L * n_per_type)
  obs$S <- "T,D,E,E"
  obs$R <- rep(rep(1:3, each = n_per_type), n_subj)
  obs
}

# T copies of the observed data with jittered RTs and the same trial structure.
.mk_ppc <- function(obs_data, T = 10L) {
  lapply(seq_len(T), function(i) {
    d    <- obs_data
    d$rt <- pmax(d$rt + rnorm(nrow(d), sd = 0.02), 0.10)
    d
  })
}

expect_monotone_quantiles <- function(out, key_cols) {
  key <- do.call(paste, out[key_cols])
  for (k in unique(key)) {
    sub <- out[key == k, ]
    sub <- sub[order(sub$quantile), ]
    expect_true(all(diff(sub$obs) >= -1e-10), info = paste("obs not monotone:", k))
    expect_true(all(diff(sub$pred_median) >= -1e-10), info = paste("pred not monotone:", k))
  }
}


# =============================================================================
# compute_dist_stats()
# =============================================================================

test_that("compute_dist_stats: one row per subject, BH-adjusted within model", {
  set.seed(123L)
  obs <- .mk_obs(n_subj = 10L, n_trials = 50L)
  out <- compute_dist_stats(.mk_ppc(obs, T = 10L), obs, "model1")

  expect_named(out, c("model", "subject", "ks_d", "ks_p", "ks_p_fdr", "fdr_pass"))
  expect_equal(out$subject, 1:10)
  expect_true(all(out$model == "model1"))
  expect_true(all(out$ks_d >= 0))
  expect_equal(out$ks_p_fdr, p.adjust(out$ks_p, method = "BH"))
  expect_equal(out$fdr_pass, out$ks_p_fdr >= PPC_AD_ALPHA)
})

test_that("compute_dist_stats: a subject with < 2 observations gets NA stats and fails", {
  set.seed(1L)
  obs <- .mk_obs(n_subj = 3L, n_trials = 20L)
  obs <- obs[!(obs$subjects == 2L & duplicated(obs$subjects)), ]   # subject 2 keeps 1 trial
  out <- compute_dist_stats(.mk_ppc(obs, T = 5L), obs, "m")

  s2 <- out[out$subject == 2L, ]
  expect_true(is.na(s2$ks_d) && is.na(s2$ks_p) && is.na(s2$ks_p_fdr))
  expect_false(s2$fdr_pass)
  expect_false(anyNA(out$ks_p[out$subject != 2L]))
})


# =============================================================================
# compute_choice_proportions()
# =============================================================================

test_that("compute_choice_proportions: proportions lie in [0, 1] and sum to 1 per condition", {
  set.seed(7L)
  obs <- .mk_obs(n_subj = 5L, n_trials = 40L)
  out <- compute_choice_proportions(.mk_ppc(obs, T = 8L), obs, "model1")

  expect_true(all(c("model", "experiment", "cue_size", "search_difficulty", "response_type",
                    "obs", "pred_median", "pred_ci_lo", "pred_ci_hi") %in% names(out)))
  expect_true(all(out$obs >= 0 & out$obs <= 1 + 1e-9))
  expect_true(all(out$pred_median >= 0 & out$pred_median <= 1 + 1e-9, na.rm = TRUE))
  sums <- out %>%
    group_by(experiment, cue_size, search_difficulty) %>%
    summarise(obs_sum = sum(obs), pred_sum = sum(pred_median), .groups = "drop")
  expect_true(all(abs(sums$obs_sum  - 1) < 1e-9))
  expect_true(all(abs(sums$pred_sum - 1) < 0.01))   # medians need not sum exactly to 1
})

test_that("compute_choice_proportions: classifies the saccaded stimulus into T / D / E", {
  set.seed(9L)
  obs <- .mk_obs_mixed(n_subj = 1L, n_per_type = 20L)
  out <- compute_choice_proportions(.mk_ppc(obs, T = 3L), obs, "model2")
  expect_setequal(out$response_type, c("T", "D", "E"))
  expect_equal(out$obs[match(c("T", "D", "E"), out$response_type)], rep(1 / 3, 3))
})


# =============================================================================
# compute_qpf_table()
# =============================================================================

test_that("compute_qpf_table: 5 monotone quantiles per condition, no response_type by default", {
  set.seed(11L)
  obs <- .mk_obs(n_subj = 4L, n_trials = 50L)
  out <- compute_qpf_table(.mk_ppc(obs, T = 10L), obs, "model1")

  expect_true(all(QPF_COLS %in% names(out)))
  expect_false("response_type" %in% names(out))
  expect_equal(sort(unique(out$quantile)), QUANTILES)
  expect_monotone_quantiles(out, c("experiment", "cue_size", "search_difficulty"))
})

test_that("compute_qpf_table: CI bounds bracket the median", {
  set.seed(15L)
  obs   <- .mk_obs(n_subj = 3L, n_trials = 40L)
  out   <- compute_qpf_table(.mk_ppc(obs, T = 20L), obs, "model5")
  valid <- !is.na(out$pred_ci_lo) & !is.na(out$pred_ci_hi) & !is.na(out$pred_median)
  expect_true(any(valid))
  expect_true(all(out$pred_ci_lo[valid] <= out$pred_median[valid] + 1e-10))
  expect_true(all(out$pred_ci_hi[valid] >= out$pred_median[valid] - 1e-10))
})

test_that("compute_qpf_table(by_response = TRUE): monotone quantiles per response type", {
  set.seed(22L)
  obs <- .mk_obs_mixed(n_subj = 3L, n_per_type = 30L)
  out <- compute_qpf_table(.mk_ppc(obs, T = 8L), obs, "model2", by_response = TRUE)

  expect_true(all(c(QPF_COLS, "response_type") %in% names(out)))
  expect_setequal(out$response_type, c("T", "D", "E"))
  expect_monotone_quantiles(out, c("experiment", "cue_size", "search_difficulty", "response_type"))
})

test_that("compute_qpf_table(by_response = TRUE): skips cells below min_n", {
  set.seed(23L)
  obs <- .mk_obs(n_subj = 3L, n_trials = 20L)   # only T responses
  out <- compute_qpf_table(.mk_ppc(obs, T = 5L), obs, "model4", by_response = TRUE, min_n = 10L)
  expect_gt(nrow(out), 0L)
  expect_true(all(out$response_type == "T"))
})
