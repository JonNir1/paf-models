#' =============================================================================
#' Level-1 tests: the simulation pipelines with EMC2 replaced by mocks.
#'
#'   - sample_posterior_alphas()  draw spacing, chain pooling, shape, capping
#'   - simulate_recovery_data()   Sigma vs variance_proportion branch, FALSE guard
#'   - run_ppc_simulation()       failed draws, checkpoint cadence, output name
#'   - run_recovery_fit()         extraction branch, ordering, forwarded config
#'   - extract_design()           reads the design from the model closure
#'
#' The real EMC2 calls behind these run end to end at L2 (PPC, simulate) and L3
#' (recovery refit).
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/fit_ppc_cloud.R")        # run_ppc_simulation + recovery helpers
source_root("R/fit/fit_recovery_cloud.R")   # run_recovery_fit
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))

SUBJECTS <- c("s1", "s2", "s3")


# =============================================================================
# sample_posterior_alphas()
# =============================================================================

#' Parameter-keyed alpha samples, as get_pars(selection = "alpha") returns them.
#' Entry [i, s] encodes sample i and subject s so draws can be traced.
alpha_samples <- function(n_samples = 10L) {
  enc <- outer(seq_len(n_samples), seq_along(SUBJECTS) / 10, `+`)
  dimnames(enc) <- list(NULL, SUBJECTS)
  list(a = enc, b = -enc)
}

test_that("sample_posterior_alphas returns evenly spaced draws as [subjects x pars] matrices", {
  local_mocks(emc_get_pars = function(...) alpha_samples(10L))
  draws <- sample_posterior_alphas(NULL, n_draws = 4L)

  expect_length(draws, 4L)
  expect_identical(dimnames(draws[[2L]]), list(SUBJECTS, c("a", "b")))
  # round(seq(1, 10, length.out = 4)) = 1, 4, 7, 10
  expect_equal(vapply(draws, function(d) d["s1", "a"], numeric(1)), c(1, 4, 7, 10) + 0.1)
  expect_equal(unname(draws[[2L]][, "b"]), -(4 + (1:3) / 10))
})

test_that("sample_posterior_alphas pools per-chain samples before drawing", {
  pooled <- alpha_samples(10L)
  local_mocks(emc_get_pars = function(...) pooled)
  from_matrix <- sample_posterior_alphas(NULL, n_draws = 4L)

  by_chain <- lapply(pooled, function(m) list(m[1:5, ], m[6:10, ]))
  local_mocks(emc_get_pars = function(...) by_chain)
  expect_identical(sample_posterior_alphas(NULL, n_draws = 4L), from_matrix)
})

test_that("sample_posterior_alphas caps n_draws at the available samples with a warning", {
  local_mocks(emc_get_pars = function(...) alpha_samples(6L))
  expect_warning(draws <- sample_posterior_alphas(NULL, n_draws = 50L), "exceeds available")
  expect_length(draws, 6L)
})


# =============================================================================
# simulate_recovery_data()
# =============================================================================

local_simulate_mocks <- function(sim = data.frame(rt = 1), env = parent.frame()) {
  rec <- call_recorder(function(...) matrix(1, 2, 2))
  local_mocks(
    extract_design          = function(model) "design",
    emc_make_random_effects = rec$fn,
    emc_make_data           = function(...) sim,
    .frame = env
  )
  rec
}

test_that("simulate_recovery_data draws from a positive-definite Sigma via covariances", {
  sigma <- diag(c(0.1, 0.2))
  rec <- local_simulate_mocks()
  expect_no_warning(out <- simulate_recovery_data(NULL, list(mu = c(a = 1, b = 2), Sigma = sigma),
                                                  data.frame(), seed = 1L))

  args <- rec$calls()[[1L]]
  expect_identical(args$covariances, sigma)
  expect_null(args$variance_proportion)
  expect_named(out, c("data", "subject_pars"))
})

test_that("simulate_recovery_data falls back to variance_proportion = 0.2 when Sigma is unusable", {
  for (sigma in list(NULL, matrix(c(1, 2, 2, 1), 2))) {
    rec <- local_simulate_mocks()
    expect_warning(simulate_recovery_data(NULL, list(mu = c(a = 1, b = 2), Sigma = sigma),
                                          data.frame(), seed = 1L),
                   "variance_proportion")
    args <- rec$calls()[[1L]]
    expect_equal(args$variance_proportion, 0.2)
    expect_null(args$covariances)
  }
})

test_that("simulate_recovery_data stops when make_data() rejects the draws", {
  local_simulate_mocks(sim = FALSE)
  expect_error(simulate_recovery_data(NULL, list(mu = c(a = 1), Sigma = diag(1)),
                                      data.frame(), seed = 1L),
               "make_data\\(\\) returned FALSE")
})


# =============================================================================
# run_ppc_simulation()
# =============================================================================

#' Mocks where draw i is a matrix filled with i; make_data() fails for `fail`.
local_ppc_mocks <- function(fail = integer(), env = parent.frame()) {
  rec <- call_recorder(function(model, n_draws, seed) {
    lapply(seq_len(n_draws), function(i) matrix(i, 2, 2))
  })
  local_mocks(
    sample_posterior_alphas = rec$fn,
    extract_design          = function(model) "design",
    emc_make_data           = function(pars, design, data) {
      if (pars[1, 1] %in% fail) stop("out of bounds")
      data.frame(draw = pars[1, 1])
    },
    .frame = env
  )
  rec
}

run_ppc <- function(dir, ...) {
  quietly(run_ppc_simulation(NULL, data.frame(subjects = c("s1", "s2")),
                             ppc_name = "m", log_file = file.path(dir, "ppc.log"),
                             out_dir = dir, ...))
}

test_that("run_ppc_simulation drops failed draws and checkpoints every save_every draws and at the end", {
  dir   <- withr::local_tempdir()
  sizes <- integer()
  paths <- character()
  hook  <- function(path, log) {
    sizes <<- c(sizes, length(readRDS(path)))
    paths <<- c(paths, path)
  }
  sampler <- local_ppc_mocks(fail = 3L)

  out <- run_ppc(dir, n_draws = 5L, save_every = 2L, sim_seed = 7L, name_suffix = "_x",
                 post_save_hook = hook)

  expect_equal(vapply(out, function(d) d$draw, numeric(1)), c(1, 2, 4, 5))
  expect_equal(sizes, c(2L, 3L, 4L))   # checkpoints after draws 2, 4 and 5
  expect_length(unique(paths), 1L)
  expect_match(basename(paths[[1L]]), "^[0-9]{6}_m_ppc_x\\.rds$")
  expect_identical(readRDS(paths[[1L]]), out)
  expect_equal(sampler$calls()[[1L]]$seed, 7L)
})

test_that("run_ppc_simulation with save_every = 0 saves once at the end", {
  dir   <- withr::local_tempdir()
  hook  <- call_recorder()
  local_ppc_mocks()
  run_ppc(dir, n_draws = 3L, save_every = 0L, post_save_hook = hook$fn)
  expect_length(hook$calls(), 1L)
})

test_that("run_ppc_simulation stops when every draw fails", {
  dir <- withr::local_tempdir()
  local_ppc_mocks(fail = 1:3)
  expect_error(run_ppc(dir, n_draws = 3L), "All make_data\\(\\) calls failed")
})


# =============================================================================
# run_recovery_fit()
# =============================================================================

SIM <- data.frame(subjects = c("s1", "s2"), rt = c(0.3, 0.4))

#' Model script whose build_model() returns its inputs; removed afterwards.
local_model_script <- function(env = parent.frame()) {
  path <- withr::local_tempfile(fileext = ".R", .local_envir = env)
  writeLines("build_model <- function(data, n_chains) list(data = data, n_chains = n_chains)", path)
  withr::defer(if (exists("build_model", envir = globalenv(), inherits = FALSE))
                 rm("build_model", envir = globalenv()), envir = env)
  path
}

#' Mocks for the recovery chain. The fit mock records, at call time, how many
#' hook calls happened and how many true_alpha files exist (in `at_fit`).
local_recovery_mocks <- function(dir, hook_log, env = parent.frame()) {
  at_fit   <- new.env()
  extract  <- call_recorder(function(model) list(mu = c(a = 1), Sigma = diag(1)))
  simulate <- call_recorder(function(...) list(data = SIM, subject_pars = matrix(2)))
  fit      <- call_recorder(function(...) {
    at_fit$hooks      <- length(hook_log())
    at_fit$true_alpha <- length(list.files(dir, "true_alpha\\.rds$"))
  })
  local_mocks(extract_group_params   = extract$fn,
              simulate_recovery_data = simulate$fn,
              fit_to_convergence     = fit$fn,
              .frame = env)
  list(extract = extract, simulate = simulate, fit = fit, at_fit = at_fit)
}

run_recovery <- function(dir, script, ...) {
  quietly(run_recovery_fit("fitted", SIM, script, recovery_name = "rec",
                           log_file = file.path(dir, "rec.log"), out_dir = dir,
                           sim_seed = 5L, ...))
}

test_that("run_recovery_fit forwards the relaxed recovery config and refits a fresh build of the simulated data", {
  dir    <- withr::local_tempdir()
  script <- local_model_script()
  hook   <- call_recorder()
  mocks  <- local_recovery_mocks(dir, hook$calls)
  gp     <- list(mu = c(a = 9), Sigma = diag(1))

  expect_identical(run_recovery(dir, script, group_params = gp, post_save_hook = hook$fn),
                   "COMPLETE")

  expect_length(mocks$extract$calls(), 0L)
  expect_identical(mocks$simulate$calls()[[1L]][[2L]], gp)
  args <- mocks$fit$calls()[[1L]]
  expect_identical(args[[1L]], list(data = SIM, n_chains = N_CHAINS))
  expect_identical(args$convergence_criteria, default_convergence_criteria("recovery"))
  expect_equal(c(args$max_tries, args$batch_size, args$save_every),
               c(MAX_TRIES_RECOVERY, STEP_SIZE_RECOVERY, SAVE_EVERY))
  expect_true(args$append_log)
  expect_identical(args$post_save_hook, hook$fn)
  expect_identical(args$save_path,
                   file.path(dir, sprintf("%s_rec.rds", format(Sys.Date(), "%y%m%d"))))
})

test_that("run_recovery_fit extracts group params when none are supplied", {
  dir   <- withr::local_tempdir()
  mocks <- local_recovery_mocks(dir, function() list())
  run_recovery(dir, local_model_script())

  expect_identical(mocks$extract$calls()[[1L]][[1L]], "fitted")
  expect_identical(mocks$simulate$calls()[[1L]][[2L]], list(mu = c(a = 1), Sigma = diag(1)))
})

test_that("run_recovery_fit saves and hooks true_alpha before the fit starts", {
  dir   <- withr::local_tempdir()
  hook  <- call_recorder()
  mocks <- local_recovery_mocks(dir, hook$calls)
  run_recovery(dir, local_model_script(), post_save_hook = hook$fn)

  expect_match(hook$calls()[[1L]][[1L]], "_rec_true_alpha\\.rds$")
  expect_identical(readRDS(hook$calls()[[1L]][[1L]]), matrix(2))
  expect_equal(mocks$at_fit$hooks, 1L)
  expect_equal(mocks$at_fit$true_alpha, 1L)
})

test_that("run_recovery_fit errors on a missing model script before any fit", {
  dir   <- withr::local_tempdir()
  mocks <- local_recovery_mocks(dir, function() list())
  expect_error(run_recovery(dir, file.path(dir, "absent.R")), "Model script not found")
  expect_length(mocks$fit$calls(), 0L)
})


# =============================================================================
# extract_design()
# =============================================================================

test_that("extract_design returns the design stored in the chain-1 model closure", {
  design   <- list(type = "mock_design")
  model_fn <- function() NULL
  environment(model_fn) <- list2env(list(design = design))
  expect_identical(extract_design(list(list(model = model_fn))), design)
})
