#' =============================================================================
#' Level-1 invariant tests (no EMC2):
#'   - config values the pipeline silently relies on (identifiability anchor,
#'     prior tables, reachable fit-loop defaults, threshold asymmetry)
#'   - fit-side check_convergence() vs eval-side verdict on the same thresholds
#'   - the test fixture's group params stay in sync with PRIOR_MU
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")
source_root("R/eval/helpers/convergence.R")
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))
source(file.path(ROOT, "__tests__", "fixtures", "test_model.R"))


# =============================================================================
# Config values
# =============================================================================

test_that("CONSTANTS pins exactly sv = log(1) = 0 (the LBA identifiability anchor)", {
  expect_identical(CONSTANTS, c(sv = 0))
})

test_that("PRIOR_MU and PRIOR_SD cover the same parameters, with finite means and positive SDs", {
  expect_identical(names(PRIOR_MU), names(PRIOR_SD))
  expect_false(anyDuplicated(names(PRIOR_MU)) > 0)
  expect_true(all(is.finite(PRIOR_MU)))
  expect_true(all(is.finite(PRIOR_SD) & PRIOR_SD > 0))
})

test_that("both convergence profiles are valid, asymmetric (mu tighter) and recovery is no stricter", {
  std <- default_convergence_criteria("standard")
  rec <- default_convergence_criteria("recovery")
  expect_true(.validate_convergence_criteria(std))
  expect_true(.validate_convergence_criteria(rec))
  expect_lte(MAX_RHAT_MU, MAX_RHAT_ALPHA)
  expect_gte(MIN_ESS_MU, MIN_ESS_ALPHA)
  for (g in c("mu", "alpha")) {
    expect_gte(rec[[g]]$max_rhat, std[[g]]$max_rhat)
    expect_lte(rec[[g]]$min_ess, std[[g]]$min_ess)
  }
})

test_that("the default fit-loop settings can reach their sample floors and checkpoint", {
  expect_true(.validate_fit_args(0, EXTENDED_FIT_SAMPLES, MAX_TRIES, STEP_SIZE,
                                 SAVE_EVERY, "x.rds", NULL))
  expect_true(.validate_fit_args(0, RECOVERY_FIT_SAMPLES, MAX_TRIES_RECOVERY, STEP_SIZE_RECOVERY,
                                 SAVE_EVERY, "x.rds", NULL))
  expect_gte(N_CHAINS, 2)   # Rhat is undefined for a single chain
})

test_that("RT cutoffs are ordered and the t0 prior mean lies below the fastest kept saccade", {
  expect_lt(MIN_SACCADE_CUTOFF, MAX_SACCADE_CUTOFF)
  expect_gt(MIN_SACCADE_CUTOFF, 0)
  expect_lt(exp(T0_MU), MIN_SACCADE_CUTOFF)
})


# =============================================================================
# Fit / eval consistency on the shared thresholds
# =============================================================================

# check_convergence() gates on strict < / >, the eval verdict fails on strict > / <
# and marks near-boundary values "marginal". The two must never contradict:
# a fit that stops as converged is never an eval "fail", and an eval "pass" is
# always converged.
test_that("check_convergence() and add_convergence_verdict() agree on every grid point", {
  cc <- default_convergence_criteria()
  for (g in c("mu", "alpha")) {
    ceil  <- cc[[g]]$max_rhat; floor <- cc[[g]]$min_ess
    for (rhat in ceil + c(-0.02, -0.005, -1e-9, 0, 1e-9, 0.01)) {
      for (ess in floor * c(0.9, 1, 1 + 1e-9, 1.1, 2)) {
        block <- matrix(c(rhat, ess), nrow = 2)
        local_mocks(emc_check = function(model, selection, ...) {
          list(mu = block, alpha = list(s1 = block))
        })
        fit_ok  <- check_convergence(list(), cc[g])$converged
        verdict <- add_convergence_verdict(data.frame(model = "m", group = g, max_rhat = rhat,
                                                      min_ess = ess, p_rhat_gt_1.01 = 0))$verdict
        lbl <- sprintf("%s rhat=%.10f ess=%.6f", g, rhat, ess)
        if (fit_ok) expect_false(verdict == "fail", label = lbl)
        if (verdict == "pass") expect_true(fit_ok, label = lbl)
      }
    }
  }
})


# =============================================================================
# Test fixture sync
# =============================================================================

test_that("test_group_params() takes its means from PRIOR_MU and errors on a missing one", {
  local_mocks(emc_sampled_pars = function(design) c(v = 0, B = 0, t0 = 0))
  gp <- test_group_params(design = NULL, sd = 0.2)
  expect_equal(gp$mu, PRIOR_MU[c("v", "B", "t0")])
  expect_equal(unname(diag(gp$Sigma)), rep(0.2, 3))
  expect_equal(dimnames(gp$Sigma), list(names(gp$mu), names(gp$mu)))

  local_mocks(emc_sampled_pars = function(design) c(v = 0, B_new = 0))
  expect_error(test_group_params(design = NULL), "No PRIOR_MU entry for sampled parameter\\(s\\): B_new")
})
