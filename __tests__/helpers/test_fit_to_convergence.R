#' =============================================================================
#' Level-1 unit tests: fit_to_convergence() input validation (no EMC2, no MCMC)
#'
#' Exercises the pure validation helpers that fail fast before any fitting:
#'   - .validate_convergence_criteria()  (criteria shape + group keys)
#'   - .validate_fit_args()              (max_tries/batch_size/save_every/
#'                                        reachability/post_save_hook)
#'   - .convergence_group_token()        (group-key aliasing)
#'   - default_convergence_criteria()    (standard / recovery profiles)
#'   - .block_rhat_ess()                 (pure check()-shape extraction; mocked
#'                                        EMC2 object shapes, no real EMC2 call)
#'   - .sample_iters()                   (fresh-vs-resume sample-stage counting)
#'   - model_log_path()                  (per-model log path derivation)
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

test_that("default_convergence_criteria rejects an unsupported profile", {
  expect_error(default_convergence_criteria("bogus"), "should be one of")
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

test_that(".convergence_group_token rejects non-character and NA keys", {
  expect_error(.convergence_group_token(NA_character_), "Unknown convergence group")
  expect_error(.convergence_group_token(123), "Unknown convergence group")
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

test_that(".validate_convergence_criteria rejects an unknown group even alongside valid ones", {
  cc <- list(num_samples = 100,
             mu      = list(max_rhat = 1.1, min_ess = 100),
             variance = list(max_rhat = 1.1, min_ess = 100))
  expect_error(.validate_convergence_criteria(cc), "Unknown convergence group")
})

test_that(".validate_convergence_criteria rejects a non-scalar num_samples", {
  expect_error(
    .validate_convergence_criteria(list(num_samples = c(100, 200),
                                        mu = list(max_rhat = 1.1, min_ess = 100))),
    "num_samples")
})

test_that(".validate_convergence_criteria rejects an NA num_samples with the informative message", {
  # An NA num_samples (e.g. parse_int_arg() returning NA_integer_ for a malformed
  # `--fit-samples abc` CLI flag) must hit the intended "must be a positive
  # integer." message via an explicit is.na() guard, not R's raw
  # "missing value where TRUE/FALSE needed" error from `if (NA)`.
  expect_error(
    .validate_convergence_criteria(list(num_samples = NA_real_,
                                        mu = list(max_rhat = 1.1, min_ess = 100))),
    "num_samples must be a positive integer"
  )
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

test_that(".validate_fit_args rejects non-positive-integer / negative max_tries and batch_size", {
  # Table of (max_tries, batch_size, expected error pattern) -- covers zero,
  # negative, and non-integer values for each argument independently.
  cases <- list(
    list(max_tries = 0,    batch_size = 50,  pattern = "max_tries"),
    list(max_tries = -3,   batch_size = 50,  pattern = "max_tries"),
    list(max_tries = 2,    batch_size = 1.5, pattern = "batch_size"),
    list(max_tries = 2,    batch_size = -10, pattern = "batch_size")
  )
  for (cs in cases) {
    expect_error(
      .validate_fit_args(0, 100, cs$max_tries, cs$batch_size, NULL, NULL, NULL),
      cs$pattern,
      info = sprintf("max_tries=%s, batch_size=%s", cs$max_tries, cs$batch_size)
    )
  }
})

test_that(".validate_fit_args enforces save_every bounds (1 <= save_every <= max_tries) + save_path presence", {
  # save_every > max_tries
  expect_error(.validate_fit_args(0, 100, 2, 100, 3, "x.rds", NULL), "save_every")
  # save_every == max_tries is the valid upper boundary
  expect_true(.validate_fit_args(0, 100, 3, 100, 3, "x.rds", NULL))
  # save_every == 1 is the valid lower boundary
  expect_true(.validate_fit_args(0, 100, 3, 100, 1, "x.rds", NULL))
  # save_every == 0 violates the documented 1 <= save_every floor
  expect_error(.validate_fit_args(0, 100, 3, 100, 0, "x.rds", NULL), "save_every")
  # save_every without save_path
  expect_error(.validate_fit_args(0, 100, 5, 100, 1, NULL, NULL), "save_path is NULL")
  # non-integer save_every
  expect_error(.validate_fit_args(0, 100, 5, 100, 1.5, "x.rds", NULL), "save_every")
})

test_that(".validate_fit_args reachability is exact at the boundary (existing + batch*tries vs num_samples)", {
  # 0 + 200 * 4 = 800 < 1000 -> unreachable
  expect_error(.validate_fit_args(0, 1000, 4, 200, NULL, NULL, NULL), "unreachable")
  # exactly at the floor: 600 + 200*2 = 1000 >= 1000 -> reachable
  expect_true(.validate_fit_args(600, 1000, 2, 200, NULL, NULL, NULL))
  # one short of the floor: 599 + 200*2 = 999 < 1000 -> unreachable
  expect_error(.validate_fit_args(599, 1000, 2, 200, NULL, NULL, NULL), "unreachable")
})

test_that(".validate_fit_args rejects a non-function post_save_hook", {
  expect_error(.validate_fit_args(0, 100, 5, 100, NULL, NULL, "not a function"),
               "post_save_hook")
})

test_that(".validate_fit_args rejects NA max_tries/batch_size with the informative message", {
  # An NA max_tries/batch_size (e.g. parse_int_arg() on a malformed CLI flag,
  # `--max-tries abc` on fit_cloud.R/fit_recovery_cloud.R) must hit the intended
  # "must be a positive integer." message via an explicit is.na() guard, not
  # R's raw "missing value where TRUE/FALSE needed" error from `if (NA)`.
  expect_error(.validate_fit_args(0, 100, NA_integer_, 50, NULL, NULL, NULL),
               "max_tries must be a positive integer")
  expect_error(.validate_fit_args(0, 100, 5, NA_integer_, NULL, NULL, NULL),
               "batch_size must be a positive integer")
})


# =============================================================================
# .block_rhat_ess()
# Pure check()-shape extraction: takes the list/matrix structure EMC2's check()
# returns and pulls max Rhat / min ESS. No EMC2 call inside the function itself,
# so we drive it entirely with mocked object shapes (per CLAUDE.md's empirically
# confirmed 3.4.1 shapes: 2-row matrix for mu/sigma2/correlation, alpha as a
# per-subject list of such matrices).
# =============================================================================

# A 2-row matrix block: row 1 = Rhat, row 2 = ESS, one column per parameter.
.mk_matrix_block <- function(rhat, ess) {
  matrix(c(rhat, ess), nrow = 2, byrow = TRUE)
}

test_that(".block_rhat_ess extracts max Rhat / min ESS from a flat matrix block (mu/sigma2/correlation shape)", {
  chk <- list(mu = .mk_matrix_block(rhat = c(1.01, 1.04, 1.02), ess = c(900, 600, 750)))
  out <- .block_rhat_ess(chk, "mu")
  expect_equal(out$max_rhat, 1.04)
  expect_equal(out$min_ess, 600)
})

test_that(".block_rhat_ess unwraps a nested list-of-one block (chk$mu$mu shape)", {
  chk <- list(mu = list(mu = .mk_matrix_block(rhat = c(1.0, 1.2), ess = c(1000, 200))))
  out <- .block_rhat_ess(chk, "mu")
  expect_equal(out$max_rhat, 1.2)
  expect_equal(out$min_ess, 200)
})

test_that(".block_rhat_ess pools across the per-subject list for the alpha shape", {
  chk <- list(alpha = list(
    subj1 = .mk_matrix_block(rhat = c(1.01, 1.05), ess = c(800, 700)),
    subj2 = .mk_matrix_block(rhat = c(1.20, 1.02), ess = c(150, 900))
  ))
  out <- .block_rhat_ess(chk, "alpha")
  expect_equal(out$max_rhat, 1.20)   # worst Rhat across all subjects x params
  expect_equal(out$min_ess, 150)     # worst ESS across all subjects x params
})

test_that(".block_rhat_ess ignores NA entries within a block via na.rm", {
  chk <- list(mu = .mk_matrix_block(rhat = c(1.01, NA, 1.03), ess = c(900, NA, 700)))
  out <- .block_rhat_ess(chk, "mu")
  expect_equal(out$max_rhat, 1.03)
  expect_equal(out$min_ess, 700)
})

test_that(".block_rhat_ess errors informatively when the requested block is absent", {
  chk <- list(mu = .mk_matrix_block(rhat = 1.0, ess = 1000))
  expect_error(.block_rhat_ess(chk, "alpha"), "no 'alpha' block")
})


# =============================================================================
# .sample_iters()
# Counts sample-stage iterations from model[[1]]$samples$stage; must return 0
# for a freshly-built (unfitted) make_emc() mock with no $samples element yet.
# =============================================================================

test_that(".sample_iters returns 0 for an unfitted mock model (no $samples)", {
  fresh_mock <- list(list(some_other_field = TRUE))   # no $samples at all
  expect_equal(.sample_iters(fresh_mock), 0L)
})

test_that(".sample_iters returns 0 for NULL or an empty list", {
  expect_equal(.sample_iters(NULL), 0L)
  expect_equal(.sample_iters(list()), 0L)
})

test_that(".sample_iters counts only stage == 'sample', ignoring burn/adapt/preburn", {
  mock_model <- list(list(samples = list(
    stage = c("preburn", "preburn", "burn", "burn", "burn", "adapt", "sample", "sample", "sample")
  )))
  expect_equal(.sample_iters(mock_model), 3L)
})

test_that(".sample_iters reads only chain 1 (chains are assumed in lockstep)", {
  mock_model <- list(
    list(samples = list(stage = rep("sample", 5))),
    list(samples = list(stage = rep("sample", 999)))   # chain 2 ignored
  )
  expect_equal(.sample_iters(mock_model), 5L)
})


# =============================================================================
# model_log_path()
# =============================================================================

test_that("model_log_path derives log_fit_<name>.txt under the given dir, stripping any .rds extension", {
  expect_equal(model_log_path("mymodel", "outputs/models/fit"),
               file.path("outputs/models/fit", "log_fit_mymodel.txt"))
  expect_equal(model_log_path("260618_mymodel.rds", "outputs/models/fit"),
               file.path("outputs/models/fit", "log_fit_260618_mymodel.txt"))
})

test_that("model_log_path strips directory components from name, keeping only the basename", {
  expect_equal(model_log_path("some/nested/path/mymodel.rds", "logs"),
               file.path("logs", "log_fit_mymodel.txt"))
})
