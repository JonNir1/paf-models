#' =============================================================================
#' Level-1 unit tests: fit_to_convergence() input validation (no EMC2, no MCMC)
#'
#' Exercises the pure validation helpers that fail fast before any fitting:
#'   - .validate_convergence_criteria()  (criteria shape + group keys)
#'   - .validate_fit_args()              (max_tries/batch_size/save_every/
#'                                        reachability/post_save_hook)
#'   - .convergence_group_token()        (group-key aliasing)
#'   - default_convergence_criteria()    (standard / recovery profiles)
#' =============================================================================

.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")   # source-time EMC2-free (library(EMC2) is call-time)


# =============================================================================
# default_convergence_criteria()
# =============================================================================

test_that("default_convergence_criteria builds the standard profile", {
  cc <- default_convergence_criteria()
  expect_equal(cc$num_samples, EXTENDED_FIT_SAMPLES)
  expect_equal(cc$mu$max_rhat, MAX_RHAT_MU)
  expect_equal(cc$alpha$min_ess, MIN_ESS_ALPHA)
  # sigma2 / correlation are descriptive-only => not gated
  expect_null(cc$sigma2)
  expect_null(cc$correlation)
})

test_that("default_convergence_criteria builds the relaxed recovery profile", {
  cc <- default_convergence_criteria("recovery")
  expect_equal(cc$num_samples, RECOVERY_FIT_SAMPLES)
  expect_equal(cc$mu$max_rhat, MAX_RHAT_MU_RECOVERY)
})


# =============================================================================
# .convergence_group_token()
# =============================================================================

test_that(".convergence_group_token maps + aliases supported groups", {
  expect_equal(.convergence_group_token("mu"), "mu")
  expect_equal(.convergence_group_token("Sigma2"), "sigma2")   # case-insensitive alias
  expect_equal(.convergence_group_token("alpha"), "alpha")
  expect_equal(.convergence_group_token("correlation"), "correlation")
})

test_that(".convergence_group_token rejects unknown groups", {
  expect_error(.convergence_group_token("variance"), "Unknown convergence group")
})


# =============================================================================
# .validate_convergence_criteria()
# =============================================================================

test_that(".validate_convergence_criteria accepts a well-formed criteria list", {
  expect_true(.validate_convergence_criteria(default_convergence_criteria()))
})

test_that(".validate_convergence_criteria rejects a missing/invalid num_samples", {
  expect_error(.validate_convergence_criteria(list(mu = list(max_rhat = 1.1, min_ess = 100))),
               "num_samples")
  expect_error(.validate_convergence_criteria(list(num_samples = 0, mu = list(max_rhat = 1.1, min_ess = 100))),
               "num_samples")
})

test_that(".validate_convergence_criteria requires at least one gated group", {
  expect_error(.validate_convergence_criteria(list(num_samples = 100)),
               "at least one group")
})

test_that(".validate_convergence_criteria requires numeric max_rhat + min_ess per group", {
  expect_error(.validate_convergence_criteria(list(num_samples = 100, mu = list(max_rhat = 1.1))),
               "max_rhat and min_ess")
})


# =============================================================================
# .validate_fit_args()
# =============================================================================

test_that(".validate_fit_args accepts a reachable, well-formed configuration", {
  expect_true(.validate_fit_args(n_samp_start = 0, num_samples = 1000,
                                 max_tries = 10, batch_size = 200,
                                 save_every = 2, save_path = "x.rds",
                                 post_save_hook = NULL))
})

test_that(".validate_fit_args rejects non-positive-integer max_tries / batch_size", {
  expect_error(.validate_fit_args(0, 100, 0, 50, NULL, NULL, NULL), "max_tries")
  expect_error(.validate_fit_args(0, 100, 2, 1.5, NULL, NULL, NULL), "batch_size")
})

test_that(".validate_fit_args enforces save_every bounds + save_path presence", {
  # save_every > max_tries
  expect_error(.validate_fit_args(0, 100, 2, 100, 3, "x.rds", NULL), "save_every")
  # save_every without save_path
  expect_error(.validate_fit_args(0, 100, 5, 100, 1, NULL, NULL), "save_path is NULL")
  # non-integer save_every
  expect_error(.validate_fit_args(0, 100, 5, 100, 1.5, "x.rds", NULL), "save_every")
})

test_that(".validate_fit_args rejects an unreachable sample floor", {
  # 0 + 200 * 4 = 800 < 1000
  expect_error(.validate_fit_args(0, 1000, 4, 200, NULL, NULL, NULL), "unreachable")
  # existing samples count toward reachability: 600 + 200*2 = 1000 >= 1000
  expect_true(.validate_fit_args(600, 1000, 2, 200, NULL, NULL, NULL))
})

test_that(".validate_fit_args rejects a non-function post_save_hook", {
  expect_error(.validate_fit_args(0, 100, 5, 100, NULL, NULL, "not a function"),
               "post_save_hook")
})
