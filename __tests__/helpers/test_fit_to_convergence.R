#' =============================================================================
#' Level-1 unit tests: fit_to_convergence() input validation (no EMC2, no MCMC)
#'
#' Exercises the pure validation helpers that fail fast before any fitting:
#'   - .validate_convergence_criteria()  (criteria shape + group keys)
#'   - .validate_fit_args()              (n_samp_start/max_tries/batch_size/
#'                                        save_every/reachability/post_save_hook)
#'   - .convergence_group_token()        (group-key aliasing)
#'   - default_convergence_criteria()    (standard / recovery profiles)
#'   - .block_rhat_ess()                 (pure check()-shape extraction)
#'   - .sample_iters()                   (fresh-vs-resume sample-stage counting)
#'   - model_log_path()                  (per-model log path derivation)
#' The fit loop itself is covered by test_fit_orchestration.R.
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")   # EMC2-free: EMC2 is reached only via emc_* wrappers

GOOD_GROUP <- list(max_rhat = 1.1, min_ess = 100)


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

test_that("default_convergence_criteria rejects an unsupported profile", {
  expect_error(default_convergence_criteria("bogus"), "should be one of")
})


# =============================================================================
# .convergence_group_token()
# =============================================================================

test_that(".convergence_group_token maps supported groups, case-insensitively", {
  cases <- c(mu = "mu", Sigma2 = "sigma2", alpha = "alpha", correlation = "correlation")
  for (key in names(cases)) expect_equal(.convergence_group_token(key), cases[[key]])
})

test_that(".convergence_group_token rejects unknown, NA and non-character keys", {
  for (key in list("variance", NA_character_, 123)) {
    expect_error(.convergence_group_token(key), "Unknown convergence group",
                 label = deparse(key))
  }
})


# =============================================================================
# .validate_convergence_criteria()
# =============================================================================

test_that(".validate_convergence_criteria accepts a well-formed criteria list", {
  expect_true(.validate_convergence_criteria(default_convergence_criteria()))
})

# NA must reach the informative message via an explicit is.na() guard, not R's
# raw "missing value where TRUE/FALSE needed" (parse_int_arg() returns NA on a
# malformed CLI flag).
test_that(".validate_convergence_criteria rejects a missing, non-positive, non-scalar or NA num_samples", {
  for (ns in list(NULL, 0, c(100, 200), NA_real_)) {
    cc <- list(num_samples = ns, mu = GOOD_GROUP)
    expect_error(.validate_convergence_criteria(cc), "num_samples must be a positive integer",
                 label = deparse(ns))
  }
})

test_that(".validate_convergence_criteria rejects no groups, incomplete groups and unknown groups", {
  cases <- list(
    list(cc = list(num_samples = 100), pattern = "at least one group"),
    list(cc = list(num_samples = 100, mu = list(max_rhat = 1.1)), pattern = "max_rhat and min_ess"),
    list(cc = list(num_samples = 100, mu = GOOD_GROUP, variance = GOOD_GROUP),
         pattern = "Unknown convergence group")
  )
  for (cs in cases) expect_error(.validate_convergence_criteria(cs$cc), cs$pattern)
})


# =============================================================================
# .validate_fit_args(n_samp_start, num_samples, max_tries, batch_size,
#                    save_every, save_path, post_save_hook)
# =============================================================================

test_that(".validate_fit_args accepts reachable configurations, incl. both save_every boundaries", {
  expect_true(.validate_fit_args(0, 1000, 10, 200, 2, "x.rds", NULL))
  expect_true(.validate_fit_args(0, 100, 3, 100, 3, "x.rds", NULL))   # save_every == max_tries
  expect_true(.validate_fit_args(0, 100, 3, 100, 1, "x.rds", function(...) NULL))
})

test_that(".validate_fit_args rejects invalid n_samp_start, max_tries and batch_size, incl. NA", {
  cases <- list(
    list(start = -1, tries = 2,           batch = 50,          pattern = "n_samp_start must be a non-negative"),
    list(start = NA, tries = 2,           batch = 50,          pattern = "n_samp_start must be a non-negative"),
    list(start = 0,  tries = 0,           batch = 50,          pattern = "max_tries must be a positive integer"),
    list(start = 0,  tries = -3,          batch = 50,          pattern = "max_tries must be a positive integer"),
    list(start = 0,  tries = NA_integer_, batch = 50,          pattern = "max_tries must be a positive integer"),
    list(start = 0,  tries = 2,           batch = 1.5,         pattern = "batch_size must be a positive integer"),
    list(start = 0,  tries = 2,           batch = -10,         pattern = "batch_size must be a positive integer"),
    list(start = 0,  tries = 5,           batch = NA_integer_, pattern = "batch_size must be a positive integer")
  )
  for (cs in cases) {
    expect_error(.validate_fit_args(cs$start, 100, cs$tries, cs$batch, NULL, NULL, NULL),
                 cs$pattern, info = deparse(cs[1:3]))
  }
})

test_that(".validate_fit_args rejects bad save_every, a missing save_path and a non-function hook", {
  cases <- list(
    list(every = 3,    path = "x.rds", hook = NULL, pattern = "save_every \\(3\\) > max_tries"),
    list(every = 0,    path = "x.rds", hook = NULL, pattern = "save_every must be a positive"),
    list(every = 1.5,  path = "x.rds", hook = NULL, pattern = "save_every must be a positive"),
    list(every = 1,    path = NULL,    hook = NULL, pattern = "save_path is NULL"),
    list(every = NULL, path = NULL,    hook = "fn", pattern = "post_save_hook")
  )
  for (cs in cases) {
    expect_error(.validate_fit_args(0, 100, 2, 100, cs$every, cs$path, cs$hook), cs$pattern)
  }
})

test_that(".validate_fit_args reachability is exact at the boundary (existing + batch*tries vs num_samples)", {
  expect_error(.validate_fit_args(0, 1000, 4, 200, NULL, NULL, NULL), "unreachable")
  expect_true(.validate_fit_args(600, 1000, 2, 200, NULL, NULL, NULL))
  expect_error(.validate_fit_args(599, 1000, 2, 200, NULL, NULL, NULL), "unreachable")
})


# =============================================================================
# .block_rhat_ess(): pure check()-shape extraction, on the confirmed 3.4.1
# shapes (2-row Rhat/ESS matrix; alpha as a per-subject list of them)
# =============================================================================

.mk_matrix_block <- function(rhat, ess) matrix(c(rhat, ess), nrow = 2, byrow = TRUE)

test_that(".block_rhat_ess takes max Rhat / min ESS from flat and nested blocks, ignoring NA", {
  flat   <- list(mu = .mk_matrix_block(c(1.01, NA, 1.04), c(900, NA, 600)))
  nested <- list(mu = list(mu = .mk_matrix_block(c(1.0, 1.2), c(1000, 200))))
  expect_equal(.block_rhat_ess(flat, "mu"),   list(max_rhat = 1.04, min_ess = 600))
  expect_equal(.block_rhat_ess(nested, "mu"), list(max_rhat = 1.2,  min_ess = 200))
})

test_that(".block_rhat_ess pools across the per-subject list for the alpha shape", {
  chk <- list(alpha = list(
    subj1 = .mk_matrix_block(c(1.01, 1.05), c(800, 700)),
    subj2 = .mk_matrix_block(c(1.20, 1.02), c(150, 900))
  ))
  expect_equal(.block_rhat_ess(chk, "alpha"), list(max_rhat = 1.20, min_ess = 150))
})

test_that(".block_rhat_ess errors informatively when the requested block is absent", {
  chk <- list(mu = .mk_matrix_block(1.0, 1000))
  expect_error(.block_rhat_ess(chk, "alpha"), "no 'alpha' block")
})


# =============================================================================
# .sample_iters() and model_log_path()
# =============================================================================

test_that(".sample_iters returns 0 for unfitted, NULL or empty models", {
  for (m in list(list(list(some_other_field = TRUE)), NULL, list())) {
    expect_equal(.sample_iters(m), 0L)
  }
})

test_that(".sample_iters counts only chain 1's sample stage, ignoring preburn/burn/adapt", {
  m <- list(
    list(samples = list(stage = c("preburn", "burn", "burn", "adapt", rep("sample", 3)))),
    list(samples = list(stage = rep("sample", 999)))   # chains are assumed in lockstep
  )
  expect_equal(.sample_iters(m), 3L)
})

test_that("model_log_path derives <dir>/log_fit_<basename>.txt, stripping .rds", {
  cases <- list(
    c("mymodel",                      "outputs/models/fit", "log_fit_mymodel.txt"),
    c("260618_mymodel.rds",           "outputs/models/fit", "log_fit_260618_mymodel.txt"),
    c("some/nested/path/mymodel.rds", "logs",               "log_fit_mymodel.txt")
  )
  for (cs in cases) expect_equal(model_log_path(cs[1], cs[2]), file.path(cs[2], cs[3]))
})
