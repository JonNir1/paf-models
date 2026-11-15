#' =============================================================================
#' Test suite entry point
#'
#' The suite is tiered by cost and intent. A higher tier always implies the
#' lower tiers also run -- TEST_LEVEL=2 runs L1+L2, TEST_LEVEL=3 runs L1+L2+L3.
#'
#'   Level 1 -- __tests__/helpers/ : unit tests, no EMC2 installed (EMC2 is
#'              reached only through the emc_* wrappers in R/helpers/emc2_api.R,
#'              which the tests mock). Seconds. Run on every push/PR. Covers the
#'              pure helpers, load_data() end to end on synthetic raw CSVs,
#'              config invariants, naming/I/O, and the fit, PPC and recovery
#'              orchestration (fit_to_convergence loop, run_ppc_simulation,
#'              run_recovery_fit, build_lba_model wiring).
#'
#'   Level 2 -- __tests__/models/  : real-EMC2 integration tests, no MCMC.
#'              Minutes. Nightly + manual dispatch.
#'                test_recovery_build.R : builds the synthetic test model ONCE
#'                  (design() dominates) and checks the build + simulate step.
#'                test_fitted_fixture.R : on the committed tiny fit
#'                  (fixtures/test_model_fitted.rds): EMC2 object shapes,
#'                  log-lik vs EMC2's own likelihood, PPC simulation.
#'
#'   Level 3 -- __tests__/fit/     : end-to-end smoke tests (tiny MCMC).
#'              About an hour; weekly + manual dispatch. test_fit_smoke.R:
#'                Smoke A/B: fit_to_convergence (fresh fit + resume)
#'                Smoke C:   recovery (extract -> simulate -> refit)
#'              Smokes run n_chains=2 with bounded stop_criteria.
#'
#' Shared helpers, mocks and constants: __tests__/fixtures/common.R.
#'
#' Run from repo root:
#'   Rscript __tests__/run_tests.R                      # level 1
#'   TEST_LEVEL=2 Rscript __tests__/run_tests.R         # levels 1-2
#'   TEST_LEVEL=3 Rscript __tests__/run_tests.R         # levels 1-3 (CI)
#' =============================================================================

library(testthat)

# Persist the repo root so test files can use it for source() and file paths,
# even after testthat::test_dir() changes the working directory.
Sys.setenv(PAF_REPO_ROOT = getwd())

level <- as.integer(Sys.getenv("TEST_LEVEL", "1"))
cat(sprintf("Running tests at TEST_LEVEL=%d\n\n", level))

testthat::test_dir("__tests__/helpers", reporter = "progress")

if (level >= 2) {
  cat("\n--- Level 2: model build tests ---\n")
  testthat::test_dir("__tests__/models", reporter = "progress")
}

if (level >= 3) {
  cat("\n--- Level 3: fit smoke tests ---\n")
  testthat::test_dir("__tests__/fit", reporter = "progress")
}
