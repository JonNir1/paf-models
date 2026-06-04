#' =============================================================================
#' Level-1 unit tests for PPC eval helpers (no EMC2 required):
#'   - compute_dist_stats()         (R/eval/helpers/ppc.R)
#'   - compute_choice_proportions() (R/eval/helpers/ppc.R)
#'   - compute_qpf_table()          (R/eval/helpers/ppc.R)
#' =============================================================================

.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)
library(dplyr)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
# eval_config.R is needed for PPC_AD_ALPHA; source directly to avoid EMC2 load
source(file.path(ROOT, "R", "eval", "eval_config.R"))
source(file.path(ROOT, "R", "eval", "helpers", "ppc.R"))


# =============================================================================
# Shared mock data helpers
# =============================================================================

# Build a minimal observed data frame with known structure.
# S = "T,E,E,E" -> target at loc 1, easy distractors elsewhere.
# All saccades (R) go to loc 1 (target), so response_type = "T" everywhere.
.mk_obs <- function(n_subj = 3L, n_trials = 20L) {
  subjects <- rep(seq_len(n_subj), each = n_trials)
  rt       <- runif(n_subj * n_trials, min = 0.25, max = 0.90)
  data.frame(
    subjects          = subjects,
    rt                = rt,
    R                 = 1L,                   # always saccade to loc 1
    S                 = "T,E,E,E",            # target at loc 1
    cue_size          = "NONE",
    search_difficulty = "EASY",
    experiment        = "exp_1",
    stringsAsFactors  = FALSE
  )
}

# Build a minimal ppc_list: T copies of obs_data with slightly jittered RTs
# but same trial structure, so proportions match exactly.
.mk_ppc <- function(obs_data, T = 10L) {
  lapply(seq_len(T), function(i) {
    d      <- obs_data
    d$rt   <- d$rt + rnorm(nrow(d), sd = 0.02)
    d$rt   <- pmax(d$rt, 0.10)
    d
  })
}


# =============================================================================
# compute_dist_stats()
# =============================================================================

test_that("compute_dist_stats returns correct columns and shape", {
  skip_if_not_installed("ADGofTest")
  set.seed(42L)
  obs  <- .mk_obs(n_subj = 4L, n_trials = 30L)
  ppcs <- .mk_ppc(obs, T = 5L)
  out  <- compute_dist_stats(ppcs, obs, "model1")

  expect_s3_class(out, "data.frame")
  expect_named(out, c("model", "subject", "ks_d", "ks_p", "ad", "ad_p",
                      "ad_p_fdr", "fdr_pass"),
               ignore.order = FALSE)
  expect_equal(nrow(out), 4L)
  expect_true(all(out$model == "model1"))
  expect_true(all(out$ks_d >= 0, na.rm = TRUE))
})

test_that("compute_dist_stats applies BH FDR within model", {
  skip_if_not_installed("ADGofTest")
  set.seed(123L)
  obs  <- .mk_obs(n_subj = 10L, n_trials = 50L)
  ppcs <- .mk_ppc(obs, T = 10L)
  out  <- compute_dist_stats(ppcs, obs, "model1")

  # ad_p_fdr should be >= ad_p (BH correction is conservative)
  valid <- !is.na(out$ad_p) & !is.na(out$ad_p_fdr)
  expect_true(all(out$ad_p_fdr[valid] >= out$ad_p[valid]))

  # fdr_pass should equal (ad_p_fdr >= PPC_AD_ALPHA)
  expect_equal(out$fdr_pass[valid],
               out$ad_p_fdr[valid] >= PPC_AD_ALPHA)
})


# =============================================================================
# compute_choice_proportions()
# =============================================================================

test_that("choice proportions sum to 1 per condition", {
  set.seed(7L)
  obs  <- .mk_obs(n_subj = 5L, n_trials = 40L)
  ppcs <- .mk_ppc(obs, T = 8L)
  out  <- compute_choice_proportions(ppcs, obs, "model1")

  expect_s3_class(out, "data.frame")
  expect_true(all(c("model", "experiment", "cue_size", "search_difficulty",
                    "response_type", "obs", "pred_median",
                    "pred_ci_lo", "pred_ci_hi") %in% names(out)))

  # Proportions (obs + pred_median) must sum to 1 per condition cell
  cond_obs_sum <- out %>%
    group_by(experiment, cue_size, search_difficulty) %>%
    summarise(obs_sum = sum(obs), pred_sum = sum(pred_median), .groups = "drop")

  expect_true(all(abs(cond_obs_sum$obs_sum  - 1) < 1e-9))
  expect_true(all(abs(cond_obs_sum$pred_sum - 1) < 0.01))  # median may not sum exactly to 1
})

test_that("choice proportions are in [0, 1]", {
  set.seed(8L)
  obs  <- .mk_obs(n_subj = 3L, n_trials = 20L)
  ppcs <- .mk_ppc(obs, T = 5L)
  out  <- compute_choice_proportions(ppcs, obs, "model1")
  expect_true(all(out$obs >= 0 & out$obs <= 1 + 1e-9))
  expect_true(all(out$pred_median >= 0 & out$pred_median <= 1 + 1e-9, na.rm = TRUE))
})

test_that("all three response types are present", {
  set.seed(9L)
  # Mix of target + easy + difficult distractors
  n <- 60L
  obs <- data.frame(
    subjects          = rep(1L, n),
    rt                = runif(n, 0.25, 0.90),
    R                 = sample(1:4, n, replace = TRUE),
    S                 = sample(c("T,E,E,E", "T,D,D,D", "T,D,E,E"), n, replace = TRUE),
    cue_size          = "NONE",
    search_difficulty = "EASY",
    experiment        = "exp_1",
    stringsAsFactors  = FALSE
  )
  ppcs <- .mk_ppc(obs, T = 3L)
  out  <- compute_choice_proportions(ppcs, obs, "model2")
  expect_true(all(c("T", "D", "E") %in% out$response_type))
})


# =============================================================================
# compute_qpf_table()
# =============================================================================

test_that("QPF quantiles are monotone within each condition", {
  set.seed(11L)
  obs  <- .mk_obs(n_subj = 4L, n_trials = 50L)
  ppcs <- .mk_ppc(obs, T = 10L)
  out  <- compute_qpf_table(ppcs, obs, "model1")

  expect_s3_class(out, "data.frame")
  expect_true(all(c("model", "experiment", "cue_size", "search_difficulty",
                    "quantile", "obs", "pred_median",
                    "pred_ci_lo", "pred_ci_hi") %in% names(out)))

  # Within each condition, obs quantiles must be non-decreasing in probability
  cond_key <- paste(out$experiment, out$cue_size, out$search_difficulty)
  for (key in unique(cond_key)) {
    sub <- out[cond_key == key, ]
    sub <- sub[order(sub$quantile), ]
    expect_true(all(diff(sub$obs) >= -1e-10),
                info = sprintf("obs quantiles not monotone for condition: %s", key))
    expect_true(all(diff(sub$pred_median) >= -1e-10),
                info = sprintf("pred_median quantiles not monotone for condition: %s", key))
  }
})

test_that("QPF returns 5 quantile levels", {
  set.seed(13L)
  obs  <- .mk_obs(n_subj = 2L, n_trials = 30L)
  ppcs <- .mk_ppc(obs, T = 5L)
  out  <- compute_qpf_table(ppcs, obs, "model4")
  expect_equal(sort(unique(out$quantile)), c(0.10, 0.25, 0.50, 0.75, 0.90))
})

test_that("CI bounds bracket the median", {
  set.seed(15L)
  obs  <- .mk_obs(n_subj = 3L, n_trials = 40L)
  ppcs <- .mk_ppc(obs, T = 20L)
  out  <- compute_qpf_table(ppcs, obs, "model5")
  valid <- !is.na(out$pred_ci_lo) & !is.na(out$pred_ci_hi) & !is.na(out$pred_median)
  expect_true(all(out$pred_ci_lo[valid] <= out$pred_median[valid] + 1e-10))
  expect_true(all(out$pred_ci_hi[valid] >= out$pred_median[valid] - 1e-10))
})
