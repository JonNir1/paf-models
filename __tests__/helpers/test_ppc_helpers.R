#' =============================================================================
#' Level-1 unit tests for PPC eval helpers (no EMC2 required):
#'   - compute_dist_stats()         (R/eval/helpers/ppc.R)
#'   - compute_choice_proportions() (R/eval/helpers/ppc.R)
#'   - compute_qpf_table()          (R/eval/helpers/ppc.R) [marginal + by_response]
#' =============================================================================

library(testthat)
library(dplyr)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
# Pin the cells these tests (and their mock data) use; the branch default of PPC_GROUP_VARS differs.
assign("PPC_GROUP_VARS", c("experiment", "cue_size", "search_difficulty"), envir = globalenv())
# eval_config.R is needed for PPC_KS_ALPHA; source directly to avoid EMC2 load
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
  expect_equal(out$fdr_pass, out$ks_p_fdr >= PPC_KS_ALPHA)
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


# =============================================================================
# Label-based matching: factor level sets / codes must not change the result
# =============================================================================

test_that("choice proportions and QPF tables depend on labels only, not factor level sets, order or codes", {
  set.seed(31L)
  obs <- .mk_obs_mixed(n_subj = 3L, n_per_type = 20L)
  obs$cue_size          <- rep(c("NONE", "SMALL"), length.out = nrow(obs))
  obs$search_difficulty <- rep(c("EASY", "MIXED"), each = 2L, length.out = nrow(obs))
  ppc <- .mk_ppc(obs, T = 6L)
  ppc_no_e <- lapply(ppc, function(d) { d$R[d$R == 3L] <- 2L; d })   # draws that never saccade to an E

  # Same labels, different encodings: observed carries the full ordered level sets, the draws
  # carry reversed / reduced / unordered ones, so integer codes and level sets disagree.
  encode_obs <- function(d) {
    d$cue_size          <- factor(d$cue_size, levels = c("NONE", "SMALL", "MEDIUM", "LARGE"), ordered = TRUE)
    d$search_difficulty <- factor(d$search_difficulty, levels = c("EASY", "MIXED", "DIFFICULT"), ordered = TRUE)
    d$R                 <- factor(d$R, levels = as.character(1:4))
    d$experiment        <- factor(d$experiment, levels = c("exp_1", "exp_2"))
    d
  }
  encode_sim <- function(d) {
    d$cue_size          <- factor(d$cue_size, levels = c("SMALL", "NONE"))
    d$search_difficulty <- factor(d$search_difficulty, levels = c("MIXED", "EASY"))
    d$R                 <- factor(d$R, levels = rev(sort(unique(as.character(d$R)))))
    d$experiment        <- factor(d$experiment)
    d
  }
  plain <- function(df) { df[] <- lapply(df, function(x) if (is.factor(x)) as.character(x) else x); df }

  for (sims in list(ppc, ppc_no_e)) {
    for (by_response in c(FALSE, TRUE)) {
      expected <- compute_qpf_table(sims, obs, "m", by_response = by_response)
      got <- compute_qpf_table(lapply(sims, encode_sim), encode_obs(obs), "m", by_response = by_response)
      expect_gt(nrow(expected), 0L)
      expect_equal(plain(got), plain(expected), ignore_attr = TRUE)
    }
    expected <- compute_choice_proportions(sims, obs, "m")
    got      <- compute_choice_proportions(lapply(sims, encode_sim), encode_obs(obs), "m")
    expect_equal(plain(got), plain(expected), ignore_attr = TRUE)
  }
  # Subjects too: the observed ones as an ordered-level factor, the draws numeric or a reduced-level factor.
  obs_f <- transform(obs, subjects = factor(subjects, levels = 3:0))
  expect_equal(compute_dist_stats(ppc, obs_f, "m")[, -2], compute_dist_stats(ppc, obs, "m")[, -2])
  expect_equal(compute_dist_stats(lapply(ppc, function(d) transform(d, subjects = factor(subjects))), obs, "m"),
               compute_dist_stats(ppc, obs, "m"))
  expect_equal(.response_type(encode_sim(ppc[[1]])), .response_type(ppc[[1]]))
  expect_equal(.response_type(encode_obs(obs)), .response_type(obs))
})


# =============================================================================
# group_vars: configurable condition cells
# =============================================================================

test_that("group_vars: the default reproduces the experiment x cue_size x search_difficulty cells; custom and missing columns are honoured", {
  set.seed(41L)
  obs <- .mk_obs_mixed(n_subj = 2L, n_per_type = 20L)
  obs$cue_size   <- rep(c("NONE", "SMALL"), length.out = nrow(obs))
  obs$experiment <- rep(c("exp_1", "exp_2"), each = 3L, length.out = nrow(obs))
  obs$prev       <- rep(c("old", "new"), each = 2L, length.out = nrow(obs))
  ppc <- .mk_ppc(obs, T = 5L)

  old_cells <- c("experiment", "cue_size", "search_difficulty")
  expect_identical(PPC_GROUP_VARS, old_cells)
  for (fn in list(compute_choice_proportions, compute_qpf_table)) {
    default  <- fn(ppc, obs, "m")
    explicit <- fn(ppc, obs, "m", group_vars = old_cells)
    expect_identical(default, explicit)
    expect_identical(names(default)[2:4], old_cells)                    # column order as before
  }

  custom <- compute_choice_proportions(ppc, obs, "m", group_vars = c("prev", "cue_size"))
  expect_identical(names(custom)[2:3], c("prev", "cue_size"))
  expect_false(any(c("experiment", "search_difficulty") %in% names(custom)))
  expect_identical(nrow(custom), 4L * 3L)                               # 4 cells x T/D/E
  expect_equal(as.numeric(tapply(custom$obs, custom[c("prev", "cue_size")], sum)), rep(1, 4))
  qpf <- compute_qpf_table(ppc, obs, "m", group_vars = "prev")
  expect_identical(nrow(qpf), 2L * 5L)

  expect_error(compute_choice_proportions(ppc, obs, "m", group_vars = c("cue_size", "nope")),
               "Grouping variable.*not in the data: nope")
  expect_error(compute_qpf_table(ppc, obs, "m", group_vars = "nope"), "not in the data: nope")

  # plot_ppc_cdf merges the two tables on the supplied grouping, so a custom grouping must build.
  skip_if_not_installed("ggplot2")
  gv    <- c("prev", "cue_size")
  p_cdf <- plot_ppc_cdf(compute_qpf_table(ppc, obs, "m", by_response = TRUE, group_vars = gv),
                        compute_choice_proportions(ppc, obs, "m", group_vars = gv),
                        x_facet = "cue_size", group_vars = gv)
  expect_gt(nrow(ggplot2::ggplot_build(p_cdf)$data[[2L]]), 0L)
  expect_error(plot_ppc_cdf(data.frame(response_type = "T"), data.frame(), x_facet = "experiment", group_vars = gv))

  # default x variable: first non-experiment grouping variable (cue_size for the default PPC_GROUP_VARS)
  expect_identical(ppc_x_var(), "cue_size")
  expect_identical(ppc_x_var(c("experiment", "prev", "cue_size")), "prev")
  expect_error(ppc_x_var("experiment"), "no variable")
  expect_identical(plot_ppc_choice(compute_choice_proportions(ppc, obs, "m", group_vars = gv),
                                   x_var = ppc_x_var(gv))$labels$x, "prev")
})
