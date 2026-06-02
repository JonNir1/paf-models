#' =============================================================================
#' Level-1 unit tests for eval-side helpers (no EMC2 required):
#'   - add_convergence_verdict()  (R/eval/helpers/convergence.R)
#'   - get_prior_sds()            (R/eval/helpers/recovery.R)
#'   - zscore_contraction()       (R/eval/helpers/recovery.R)
#' =============================================================================

.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "eval", "helpers", "convergence.R"))
source(file.path(ROOT, "R", "eval", "helpers", "recovery.R"))


# =============================================================================
# add_convergence_verdict()
# =============================================================================

# Minimal conv_table with the columns the verdict function reads.
.mk_conv <- function(group, max_rhat, min_ess, p_rhat_gt_1.01) {
  data.frame(model = "m", group = group, max_rhat = max_rhat,
             min_ess = min_ess, p_rhat_gt_1.01 = p_rhat_gt_1.01,
             stringsAsFactors = FALSE)
}

# Fixed thresholds for hermetic tests (mirror R/config.R defaults).
TH <- list(rmu = 1.05, emu = 500, ral = 1.10, eal = 400)
verdict1 <- function(tbl) {
  add_convergence_verdict(tbl, max_rhat_mu = TH$rmu, min_ess_mu = TH$emu,
                          max_rhat_alpha = TH$ral, min_ess_alpha = TH$eal)$verdict
}

test_that("sigma2 / correlation blocks are always 'descriptive'", {
  expect_equal(verdict1(.mk_conv("sigma2", 1.30, 100, 60)), "descriptive")
  expect_equal(verdict1(.mk_conv("correlation", 1.40, 50, 80)), "descriptive")
})

test_that("clean mu / alpha -> 'pass'", {
  expect_equal(verdict1(.mk_conv("mu", 1.010, 1200, 5)), "pass")
  expect_equal(verdict1(.mk_conv("alpha", 1.020, 900, 6)), "pass")
})

test_that("threshold breach -> 'fail'", {
  expect_equal(verdict1(.mk_conv("mu", 1.060, 1200, 5)), "fail")   # Rhat > 1.05
  expect_equal(verdict1(.mk_conv("mu", 1.010, 480, 5)),  "fail")   # ESS < 500
  expect_equal(verdict1(.mk_conv("alpha", 1.120, 900, 5)), "fail") # Rhat > 1.10
  expect_equal(verdict1(.mk_conv("alpha", 1.020, 390, 5)), "fail") # ESS < 400
})

test_that("near-boundary or many-high-Rhat -> 'marginal'", {
  expect_equal(verdict1(.mk_conv("mu", 1.048, 1200, 5)),  "marginal") # within 0.005 of 1.05
  expect_equal(verdict1(.mk_conv("mu", 1.010, 540, 5)),   "marginal") # ESS within 10% of 500
  expect_equal(verdict1(.mk_conv("mu", 1.010, 1200, 30)), "marginal") # > 25% Rhat > 1.01
  expect_equal(verdict1(.mk_conv("alpha", 1.020, 430, 5)),"marginal") # ESS within 10% of 400
})

test_that("reproduces the real model4/model5 = marginal verdict", {
  # From the live convergence table (model4 alpha: 1.097 / 423 / 14.4%).
  expect_equal(verdict1(.mk_conv("alpha", 1.097, 423, 14.4)), "marginal")
  # model5 mu: 1.048 / 1001 / 40%.
  expect_equal(verdict1(.mk_conv("mu", 1.048, 1001, 40)), "marginal")
  # model1 mu: 1.023 / 1047 / 7.1% -> pass.
  expect_equal(verdict1(.mk_conv("mu", 1.023, 1047, 7.1)), "pass")
})

test_that("per-metric verdicts split Rhat and ESS independently", {
  # model5$mu: marginal on Rhat (1.048 near 1.05), but ESS 1001 passes.
  out <- add_convergence_verdict(.mk_conv("mu", 1.048, 1001, 40),
                                 max_rhat_mu = TH$rmu, min_ess_mu = TH$emu,
                                 max_rhat_alpha = TH$ral, min_ess_alpha = TH$eal)
  expect_equal(out$verdict_rhat, "marginal")
  expect_equal(out$verdict_ess,  "pass")
  expect_equal(out$verdict,      "marginal")   # combined = worse of the two
})

test_that("metric_verdict labels descriptive blocks regardless of metric", {
  th <- list(rhat_mu = 1.05, ess_mu = 500, rhat_alpha = 1.10, ess_alpha = 400)
  expect_equal(metric_verdict("sigma2", "rhat", 1.30, 60, th), "descriptive")
  expect_equal(metric_verdict("correlation", "ess", 100, thresholds = th), "descriptive")
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

test_that("z-score and contraction match closed-form values", {
  # post_sd = 0.5, prior_sd = 1 -> contraction = 1 - 0.25/1 = 0.75
  # est = 1.5, true = 1.0 -> z = 0.5 / 0.5 = 1.0
  zc <- zscore_contraction(mu_est = 1.5, mu_true = 1.0, post_sd = 0.5, prior_sd = 1.0)
  expect_equal(zc$z_score, 1.0)
  expect_equal(zc$contraction, 0.75)
})

test_that("zscore_contraction is vectorised and propagates NA prior_sd", {
  zc <- zscore_contraction(
    mu_est   = c(1.0, 2.0),
    mu_true  = c(1.0, 1.0),
    post_sd  = c(0.5, 0.5),
    prior_sd = c(1.0, NA)
  )
  expect_equal(zc$z_score, c(0, 2))
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
