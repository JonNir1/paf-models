#' =============================================================================
#' Test suite entry point
#'
#' Runs tests up to the requested TEST_LEVEL (env var, default 1):
#'   Level 1 — helpers/ unit tests (fast, <1 s each; no EMC2)
#'   Level 2 — models/ build tests (seconds-minutes; requires EMC2 + fixture)
#'   Level 3 — fit/ smoke tests    (minutes-hours; CI only)
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
