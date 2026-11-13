#' =============================================================================
#' Level-1 unit tests for eval-side helpers (no EMC2 required):
#'   - add_convergence_verdict() / metric_verdict()  (R/eval/helpers/convergence.R)
#'   - get_prior_sds(), zscore_contraction(), flag_identifiable(),
#'     recovery_model_summary()                       (R/eval/helpers/recovery.R)
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "eval", "helpers", "convergence.R"))
source(file.path(ROOT, "R", "eval", "helpers", "recovery.R"))


# =============================================================================
# add_convergence_verdict() / metric_verdict()
# =============================================================================

# Fixed thresholds for hermetic tests (mirror the R/config.R defaults).
TH <- list(rhat_mu = 1.05, ess_mu = 500, rhat_alpha = 1.10, ess_alpha = 400)

verdict_table <- function(rows) {
  tbl <- data.frame(model = "m",
                    group          = vapply(rows, `[[`, "", "group"),
                    max_rhat       = vapply(rows, `[[`, 0, "rhat"),
                    min_ess        = vapply(rows, `[[`, 0, "ess"),
                    p_rhat_gt_1.01 = vapply(rows, `[[`, 0, "p_hi"),
                    stringsAsFactors = FALSE)
  add_convergence_verdict(tbl, max_rhat_mu = TH$rhat_mu, min_ess_mu = TH$ess_mu,
                          max_rhat_alpha = TH$rhat_alpha, min_ess_alpha = TH$ess_alpha)
}
row <- function(group, rhat, ess, p_hi, verdict, why) {
  list(group = group, rhat = rhat, ess = ess, p_hi = p_hi, verdict = verdict, why = why)
}

test_that("add_convergence_verdict: block verdicts across descriptive / pass / marginal / fail", {
  rows <- list(
    row("sigma2",      1.30,  100,  60,   "descriptive", "never gated"),
    row("correlation", 1.40,  50,   80,   "descriptive", "never gated"),
    row("mu",          1.010, 1200, 5,    "pass",        "clean mu"),
    row("alpha",       1.020, 900,  6,    "pass",        "clean alpha"),
    row("mu",          1.023, 1047, 7.1,  "pass",        "real model1 mu"),
    row("mu",          1.060, 1200, 5,    "fail",        "mu Rhat > 1.05"),
    row("mu",          1.010, 480,  5,    "fail",        "mu ESS < 500"),
    row("alpha",       1.120, 900,  5,    "fail",        "alpha Rhat > 1.10"),
    row("alpha",       1.020, 390,  5,    "fail",        "alpha ESS < 400"),
    row("mu",          1.048, 1200, 5,    "marginal",    "Rhat within 0.005 of the ceiling"),
    row("mu",          1.050, 1200, 5,    "marginal",    "Rhat exactly at the ceiling is not a fail"),
    row("mu",          1.010, 500,  5,    "marginal",    "ESS exactly at the floor is not a fail"),
    row("mu",          1.010, 540,  5,    "marginal",    "ESS within 10% of 500"),
    row("mu",          1.010, 1200, 30,   "marginal",    "> 25% of Rhat > 1.01"),
    row("mu",          1.010, 1200, 25,   "pass",        "exactly 25% of Rhat > 1.01"),
    row("alpha",       1.097, 423,  14.4, "marginal",    "real model4 alpha"),
    row("alpha",       1.020, 430,  5,    "marginal",    "alpha ESS within 10% of 400"),
    row("theta",       1.000, 9999, 0,    NA_character_, "unknown group")
  )
  out <- verdict_table(rows)
  for (i in seq_along(rows)) {
    expect_identical(out$verdict[i], rows[[i]]$verdict, label = rows[[i]]$why)
  }
})

test_that("add_convergence_verdict: Rhat and ESS verdicts split; combined is the worse", {
  out <- verdict_table(list(row("mu", 1.048, 1001, 40, NA, "real model5 mu"),
                            row("alpha", 1.01, 390, 0, NA, "ESS fail only")))
  expect_equal(out$verdict_rhat, c("marginal", "pass"))
  expect_equal(out$verdict_ess,  c("pass", "fail"))
  expect_equal(out$verdict,      c("marginal", "fail"))
})

test_that("metric_verdict: descriptive for sigma2/correlation, NA for unknown groups, error on bad metric", {
  expect_equal(metric_verdict("sigma2", "rhat", 1.30, 60, TH), "descriptive")
  expect_equal(metric_verdict("correlation", "ess", 100, thresholds = TH), "descriptive")
  expect_identical(metric_verdict("theta", "rhat", 1.0, thresholds = TH), NA_character_)
  expect_error(metric_verdict("mu", "bulk", 1.0, thresholds = TH), "metric must be")
})


# =============================================================================
# get_prior_sds()
# =============================================================================

test_that("get_prior_sds returns sqrt(diag(theta_mu_var)) with names", {
  pars <- c("v", "B", "t0")
  V    <- diag(c(4, 1, 0.25)); rownames(V) <- colnames(V) <- pars
  mock_model <- list(list(prior = list(theta_mu_var = V)))
  sds <- get_prior_sds(mock_model)
  expect_equal(unname(sds), c(2, 1, 0.5))
  expect_equal(names(sds), pars)
})

test_that("get_prior_sds errors on missing prior layout", {
  expect_error(get_prior_sds(list(list(prior = list()))), "theta_mu_var")
})


# =============================================================================
# zscore_contraction()
# =============================================================================

test_that("zscore_contraction matches closed form, is vectorised, propagates NA prior_sd", {
  # post_sd = 0.5, prior_sd = 1 -> contraction = 1 - 0.25/1 = 0.75; z = (est - true) / post_sd
  zc <- zscore_contraction(
    mu_est   = c(1.5, 2.0),
    mu_true  = c(1.0, 1.0),
    post_sd  = c(0.5, 0.5),
    prior_sd = c(1.0, NA)
  )
  expect_equal(zc$z_score, c(1, 2))
  expect_equal(zc$contraction[1], 0.75)
  expect_true(is.na(zc$contraction[2]))
})


# =============================================================================
# flag_identifiable() / recovery_model_summary()
# =============================================================================

PAT <- "^v_StimulusAtLoc[DE](:SearchDifficulty(MIXED|DIFFICULT))?$"

test_that("flag_identifiable marks the StimulusAtLoc x SearchDifficulty block FALSE", {
  pars <- c("v", "v_PrevTargetAtLocTRUE", "B",
            "v_StimulusAtLocD", "v_StimulusAtLocE",
            "v_StimulusAtLocD:SearchDifficultyMIXED",
            "v_StimulusAtLocE:SearchDifficultyDIFFICULT")
  flag <- flag_identifiable(pars, pattern = PAT)
  expect_equal(flag, c(TRUE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE))
})

test_that("recovery_model_summary computes full and core means", {
  ss <- data.frame(
    model     = "model4",
    parameter = c("v", "v_StimulusAtLocD", "v_StimulusAtLocE:SearchDifficultyDIFFICULT"),
    n         = 10,
    rmse      = c(0.2, 0.9, 8.0),
    r         = c(0.9, -0.3, -0.7),
    stringsAsFactors = FALSE
  )
  out <- recovery_model_summary(ss, pattern = PAT)
  expect_equal(out$n_all, 3)
  expect_equal(out$n_core, 1)              # only "v" survives
  expect_equal(out$r_core, 0.9)            # core mean = just v
  expect_equal(round(out$r_all, 4), round(mean(c(0.9, -0.3, -0.7)), 4))
})
