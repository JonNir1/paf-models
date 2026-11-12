#' =============================================================================
#' Level-2 tests on the committed fitted fixture (__tests__/fixtures/
#' test_model_fitted.rds): real EMC2 calls on a real (tiny, unconverged) fit,
#' with no MCMC and no design() build. Skips with a regenerate hint when the
#' fixture's EMC2 major.minor differs from the installed one.
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/fit_ppc_cloud.R")   # run_ppc_simulation + recovery helpers
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))

FITTED <- load_fitted_fixture()
DATA   <- load_fixture_data()


test_that("run_ppc_simulation simulates n_draws datasets with the template's trial structure", {
  dir     <- withr::local_tempdir()
  n_draws <- 5L
  sims <- quietly(run_ppc_simulation(FITTED, DATA, ppc_name = "test_model",
                                     log_file = file.path(dir, "ppc.log"), out_dir = dir,
                                     n_draws = n_draws, sim_seed = RNG_SEED))

  expect_length(sims, n_draws)
  for (sim in sims) {
    expect_s3_class(sim, "data.frame")
    expect_equal(nrow(sim), nrow(DATA))
    expect_identical(as.character(sim$subjects), as.character(DATA$subjects))
    expect_identical(levels(sim$R), levels(DATA$R))
    expect_true(all(is.finite(sim$rt) & sim$rt > 0))
  }
  expect_identical(readRDS(list.files(dir, "_test_model_ppc\\.rds$", full.names = TRUE)), sims)
})
