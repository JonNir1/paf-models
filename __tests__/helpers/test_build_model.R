#' =============================================================================
#' Level-1 tests: build_lba_model() wiring and prior selection, with the EMC2
#' design/prior/make_emc calls mocked. The real build runs once at L2.
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/helpers/build_model.R")
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))

#' Mocks where the design samples `sampled` (in that order).
local_build_mocks <- function(sampled, env = parent.frame()) {
  design <- call_recorder(function(...) "design")
  prior  <- call_recorder(function(...) "prior")
  emc    <- call_recorder(function(...) "emc")
  local_mocks(
    emc_design       = design$fn,
    emc_sampled_pars = function(design) setNames(rep(0, length(sampled)), sampled),
    emc_prior        = prior$fn,
    emc_make_emc     = emc$fn,
    .frame = env
  )
  list(design = design, prior = prior, emc = emc)
}

build <- function(...) {
  build_lba_model(data.frame(), v_formula = v ~ CueAtLoc, B_formula = B ~ 1,
                  sv_formula = sv ~ TargetAtLoc, ...)
}

test_that("design() gets CONSTANTS, the five formulas and, by default, all five factor closures (a `functions` override replaces them)", {
  mocks <- local_build_mocks("v")
  expect_identical(build(n_chains = 4L), "emc")

  args <- mocks$design$calls()[[1L]]
  expect_identical(args$constants, CONSTANTS)
  expect_identical(args$functions[c("PrevTargetAtLoc", "CueAtLoc", "StimulusAtLoc",
                                    "TargetAtLoc", "SearchDifficulty")],
                   list(PrevTargetAtLoc = PrevTargetAtLoc, CueAtLoc = CueAtLoc,
                        StimulusAtLoc = StimulusAtLoc, TargetAtLoc = TargetAtLoc,
                        SearchDifficulty = SearchDifficulty))
  expect_identical(vapply(args$formula, function(f) deparse(f), character(1)),
                   c("v ~ CueAtLoc", "sv ~ TargetAtLoc", "B ~ 1", "A ~ 1", "t0 ~ 1"))
  expect_identical(mocks$emc$calls()[[1L]]$n_chains, 4L)

  build(functions = list(CueAtLoc = CueAtLoc, TargetAtLoc = TargetAtLoc))
  expect_named(mocks$design$calls()[[2L]]$functions, c("CueAtLoc", "TargetAtLoc"))

  # sv_formula has no default any more: forgetting it fails before design() is called.
  expect_error(build_lba_model(data.frame(), v_formula = v ~ CueAtLoc, B_formula = B ~ 1), "sv_formula")
  expect_length(mocks$design$calls(), 2L)
})

test_that("prior means and SDs are taken from the master table in sampled_pars() order", {
  sampled <- c("t0", "v", "B", "A")
  mocks <- local_build_mocks(sampled)
  build()

  args <- mocks$prior$calls()[[1L]]
  expect_identical(args$mu_mean, PRIOR_MU[sampled])
  expect_identical(args$mu_sd,   PRIOR_SD[sampled])
  expect_identical(args$type, "standard")
})

test_that("extra_mu / extra_sd override existing entries and add model-specific ones", {
  mocks <- local_build_mocks(c("v", "v_new"))
  build(extra_mu = c(v = 9, v_new = 3), extra_sd = c(v = 0.5, v_new = 0.25))

  args <- mocks$prior$calls()[[1L]]
  expect_identical(args$mu_mean, c(v = 9, v_new = 3))
  expect_identical(args$mu_sd,   c(v = 0.5, v_new = 0.25))
})

test_that("a sampled parameter without a prior mean or SD errors and names it", {
  local_build_mocks(c("v", "v_ghost"))
  expect_error(build(), "No prior defined for sampled parameter\\(s\\): v_ghost")

  local_build_mocks(c("v", "v_new"))
  expect_error(build(extra_mu = c(v_new = 3)), "v_new")
})
