#' =============================================================================
#' Test suite entry point
#'
#' The suite is tiered by cost and intent. A higher tier always implies the
#' lower tiers also run -- TEST_LEVEL=2 runs L1+L2, TEST_LEVEL=3 runs L1+L2+L3.
#'
#'   Level 1 -- __tests__/helpers/ : unit tests for pure helpers.
#'              Fast (<5 s total), no EMC2 dependency. Run on every push/PR.
#'              Files include test_logging.R, test_data.R, test_model_helpers.R,
#'              test_recovery.R, test_fit_to_convergence.R (input validation).
#'
#'   Level 2 -- __tests__/models/  : model-build integration tests.
#'              Seconds--minutes, requires EMC2 + the committed sample_data.csv
#'              fixture. Builds the synthetic test model (__tests__/fixtures/
#'              test_model.R) once and guards build_lba_model()/make_emc() plus
#'              the extract -> simulate -> build_model recovery chain. No MCMC.
#'              File: test_recovery_build.R (+ shared_assertions.R).
#'
#'   Level 3 -- __tests__/fit/     : end-to-end smoke tests (tiny MCMC).
#'              Minutes--hours; CI-only (manual dispatch). One file
#'              (test_fit_smoke.R), all driven by the synthetic test model:
#'                Smoke A/B: fit_to_convergence (fresh fit + resume)
#'                Smoke C:   recovery (extract -> simulate -> refit)
#'                Smoke D:   PPC simulation
#'              Smokes run n_chains=2 with bounded stop_criteria.
#'
#' Run from repo root:
#'   Rscript __tests__/run_tests.R                      # level 1
#'   TEST_LEVEL=2 Rscript __tests__/run_tests.R         # levels 1-2
#'   TEST_LEVEL=3 Rscript __tests__/run_tests.R         # levels 1-3 (CI)
#' =============================================================================

.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
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
