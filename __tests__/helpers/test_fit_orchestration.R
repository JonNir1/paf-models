#' =============================================================================
#' Level-1 tests: fit_to_convergence() control flow and check_convergence()
#' gating, with EMC2 replaced by mocks of the emc_* seam (no EMC2, no MCMC).
#'
#' The L3 smokes still run the real fresh + resume fit end to end; these cover
#' the branches the smokes cannot reach deterministically (exhausted tries,
#' floor-not-met, checkpoint cadence, strict thresholds).
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))

CC <- list(num_samples = 40L, mu = list(max_rhat = 1.1, min_ess = 10))

#' Mock emc_fit / emc_run that append `iter` / `step_size` sample iterations,
#' plus a scripted check_convergence(). Returns the two call recorders.
local_fit_mocks <- function(verdicts, env = parent.frame()) {
  fit_rec <- call_recorder(function(emc, ..., iter) add_sample_iters(emc, iter))
  run_rec <- call_recorder(function(emc, ..., step_size) add_sample_iters(emc, step_size))
  local_mocks(
    emc_fit           = fit_rec$fn,
    emc_run           = run_rec$fn,
    check_convergence = scripted_convergence(verdicts),
    .frame = env
  )
  list(fit = fit_rec, run = run_rec)
}

run_fit <- function(emc, ...) {
  quietly(fit_to_convergence(emc, convergence_criteria = CC, batch_size = 20L, ...))
}


# =============================================================================
# fit_to_convergence(): warm-up vs resume, loop termination
# =============================================================================

test_that("fresh model warms up once via emc_fit(iter = batch_size, init_stop_criteria); resume skips it", {
  stop_crit <- list(sample = list(iter = 20L, max_gd = Inf))
  mocks <- local_fit_mocks(TRUE)
  res <- run_fit(mock_emc(0L), max_tries = 3L, init_stop_criteria = stop_crit)

  expect_length(mocks$fit$calls(), 1L)
  fit_args <- mocks$fit$calls()[[1L]]
  expect_equal(fit_args$iter, 20L)
  expect_identical(fit_args$stop_criteria, stop_crit)

  mocks <- local_fit_mocks(TRUE)
  run_fit(mock_emc(40L), max_tries = 3L)
  expect_length(mocks$fit$calls(), 0L)
})

test_that("loop termination: tries, emc_run calls and verdict per scenario", {
  # verdicts: pre-loop check first, then one per try.
  cases <- list(
    list(name = "already converged pre-loop", start = 40L, verdicts = TRUE,
         n_tries = 0L, converged = TRUE, n_samples = 40L),
    list(name = "Rhat/ESS met but floor not met keeps sampling", start = 20L, verdicts = TRUE,
         n_tries = 1L, converged = TRUE, n_samples = 40L),
    list(name = "stops at first try meeting both", start = 40L,
         verdicts = c(FALSE, FALSE, TRUE, TRUE),
         n_tries = 2L, converged = TRUE, n_samples = 80L),
    list(name = "max_tries exhausted", start = 40L, verdicts = FALSE,
         n_tries = 4L, converged = FALSE, n_samples = 120L)
  )
  for (cs in cases) {
    mocks <- local_fit_mocks(cs$verdicts)
    res <- run_fit(mock_emc(cs$start), max_tries = 4L)
    expect_equal(res$n_tries, cs$n_tries, info = cs$name)
    expect_length(mocks$run$calls(), cs$n_tries)
    expect_identical(res$converged, cs$converged, info = cs$name)
    expect_equal(res$n_samples, cs$n_samples, info = cs$name)
  }
})

test_that("each try asks emc_run for exactly one additive sample batch", {
  mocks <- local_fit_mocks(c(FALSE, TRUE))
  run_fit(mock_emc(40L), max_tries = 2L)
  args <- mocks$run$calls()[[1L]]
  expect_equal(args$stage, "sample")
  expect_equal(args$stop_criteria$iter, 20L)
  expect_equal(args$step_size, 20L)
  expect_equal(args$max_tries, 1)
})


# =============================================================================
# fit_to_convergence(): checkpoint cadence and post-save hook
# =============================================================================

test_that("saves after warm-up, every save_every tries and at the end, hooking (save_path, log_file) each time", {
  dir       <- withr::local_tempdir()
  save_path <- file.path(dir, "nested", "fit.rds")
  log_file  <- file.path(dir, "fit.log")
  hook      <- call_recorder()
  local_fit_mocks(FALSE)

  res <- run_fit(mock_emc(0L), max_tries = 5L, save_every = 2L, save_path = save_path,
                 log_file = log_file, post_save_hook = hook$fn)

  # warm-up + tries 2 and 4 + final
  expect_length(hook$calls(), 4L)
  for (args in hook$calls()) expect_identical(args, list(save_path, log_file))
  expect_identical(res$saved_path, save_path)
  expect_equal(.sample_iters(readRDS(save_path)), res$n_samples)
})

test_that("save_path = NULL writes nothing and never calls the hook", {
  dir  <- withr::local_tempdir()
  hook <- call_recorder()
  local_fit_mocks(FALSE)
  withr::local_dir(dir)

  res <- run_fit(mock_emc(0L), max_tries = 2L, post_save_hook = hook$fn)

  expect_null(res$saved_path)
  expect_length(hook$calls(), 0L)
  expect_length(list.files(dir, recursive = TRUE), 0L)
})


# =============================================================================
# check_convergence(): gating over a mocked check() result
# =============================================================================

#' check() block: row 1 = Rhat, row 2 = ESS.
blk <- function(rhat, ess) matrix(c(rhat, ess), nrow = 2, byrow = TRUE)

local_check <- function(chk, env = parent.frame()) {
  rec <- call_recorder(function(...) chk)
  local_mocks(emc_check = rec$fn, .frame = env)
  rec
}

test_that("check_convergence gates only the groups named in the criteria", {
  rec <- local_check(list(mu    = blk(1.01, 900),
                          alpha = list(s1 = blk(9.9, 1))))
  cv <- check_convergence(mock_emc(), CC)

  expect_true(cv$converged)
  expect_named(cv$groups, "mu")
  expect_identical(rec$calls()[[1L]]$selection, "mu")
})

test_that("check_convergence thresholds are strict and every gated group must pass", {
  cc2 <- list(num_samples = 1L,
              mu    = list(max_rhat = 1.05, min_ess = 500),
              alpha = list(max_rhat = 1.10, min_ess = 400))
  ok_alpha <- list(s1 = blk(1.02, 900), s2 = blk(1.03, 800))
  cases <- list(
    list(name = "both inside",     mu = blk(1.049, 501), alpha = ok_alpha, expected = TRUE),
    list(name = "Rhat == max",     mu = blk(1.05, 900),  alpha = ok_alpha, expected = FALSE),
    list(name = "ESS == min",      mu = blk(1.01, 500),  alpha = ok_alpha, expected = FALSE),
    list(name = "one subject bad", mu = blk(1.01, 900),
         alpha = list(s1 = blk(1.02, 900), s2 = blk(1.2, 900)), expected = FALSE)
  )
  for (cs in cases) {
    local_check(list(mu = cs$mu, alpha = cs$alpha))
    expect_identical(check_convergence(mock_emc(), cc2)$converged, cs$expected, info = cs$name)
  }
})

test_that("check_convergence refuses criteria that gate no group", {
  local_check(list(mu = blk(1, 1000)))
  expect_error(check_convergence(mock_emc(), list(num_samples = 10L)), "gates no parameter groups")
})
