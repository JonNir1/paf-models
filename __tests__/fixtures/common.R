#' =============================================================================
#' Shared test infrastructure, sourced by every tier.
#'
#'   - quietly()            : evaluate while swallowing log_msg() console output
#'   - mock_emc()           : minimal EMC2-shaped object (per-chain $samples$stage)
#'   - add_sample_iters()   : append sample-stage iterations to a mock_emc()
#'   - scripted_convergence(): check_convergence() stand-in returning a fixed
#'                            sequence of verdicts
#'   - call_recorder()      : function stand-in that records every call's args
#'
#'   - local_mocks()        : temporarily rebind sourced functions in globalenv
#'   - load_fixture_raw() / load_fixture_data(): sample_data.csv, factor-encoded
#'                            by the production .encode_factors() (+ filter_data)
#'   - SMOKE_STOP_CRITERIA, TRIVIAL_CC: bounded tiny-MCMC settings (L3 smokes and
#'                            the fitted-fixture generator)
#'   - load_fitted_fixture(): committed tiny fit; skips when its EMC2 major.minor
#'                            differs from the installed one
#'
#' The mocks replace the emc_* seam (R/helpers/emc2_api.R) and sourced pipeline
#' functions, so L1 exercises orchestration without EMC2 installed.
#' testthat::local_mocked_bindings() needs a package namespace, which this repo
#' does not have; rlang::local_bindings() (a testthat dependency) on globalenv is
#' the equivalent for sourced code.
#' =============================================================================

local_mocks <- function(..., .frame = parent.frame()) {
  rlang::local_bindings(..., .env = globalenv(), .frame = .frame)
}


quietly <- function(expr) {
  out <- NULL
  utils::capture.output(out <- expr)
  out
}


mock_emc <- function(n_sample = 0L, n_chains = 2L) {
  stage <- c(rep("burn", 3L), rep("sample", n_sample))
  rep(list(list(samples = list(stage = stage))), n_chains)
}


add_sample_iters <- function(emc, n) {
  lapply(emc, function(chain) {
    chain$samples$stage <- c(chain$samples$stage, rep("sample", n))
    chain
  })
}


#' @param verdicts Logical vector; call i returns verdicts[min(i, length)].
scripted_convergence <- function(verdicts) {
  i <- 0L
  function(model, convergence_criteria) {
    i <<- i + 1L
    list(converged = verdicts[[min(i, length(verdicts))]], groups = list())
  }
}


#' Records the arguments of every call; `impl` produces the return value.
#' Use rec$fn as the mock, rec$calls() for the list of argument lists.
call_recorder <- function(impl = function(...) invisible(NULL)) {
  calls <- list()
  list(
    fn    = function(...) {
      calls[[length(calls) + 1L]] <<- list(...)
      impl(...)
    },
    calls = function() calls
  )
}


# -----------------------------------------------------------------------------
# Fixture data (needs R/helpers/data.R and R/config.R sourced)
# -----------------------------------------------------------------------------

FIXTURES_DIR   <- file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "__tests__", "fixtures")
FITTED_FIXTURE <- file.path(FIXTURES_DIR, "test_model_fitted.rds")

load_fixture_raw <- function() {
  .encode_factors(readr::read_csv(file.path(FIXTURES_DIR, "sample_data.csv"),
                                  show_col_types = FALSE))
}

load_fixture_data <- function() {
  filter_data(load_fixture_raw(),
              min_rt               = MIN_SACCADE_CUTOFF,
              max_rt               = MAX_SACCADE_CUTOFF,
              allow_target_repeats = ALLOW_TARGET_REPEAT)
}


# -----------------------------------------------------------------------------
# Tiny-MCMC settings
# -----------------------------------------------------------------------------

# max_gd = Inf makes each EMC2 phase exit after its minimum iteration count,
# preventing covariance degeneracy with tiny chains. Passed as init_stop_criteria
# to the warm-up fit() inside fit_to_convergence().
SMOKE_STOP_CRITERIA <- list(
  preburn = list(iter = 10L, max_gd = Inf),
  burn    = list(iter = 20L, max_gd = Inf),
  adapt   = list(iter = 10L, max_gd = Inf),
  sample  = list(iter = 20L, max_gd = Inf)
)

# Trivially satisfied Rhat/ESS gates, so convergence is decided by the
# sample-stage floor alone. The floor (40) exceeds the warm-up sample count (20)
# so the extension loop runs on a fresh fit.
TRIVIAL_CC <- list(
  num_samples = 40L,
  mu          = list(max_rhat = 1e6, min_ess = 0),
  alpha       = list(max_rhat = 1e6, min_ess = 0)
)


# -----------------------------------------------------------------------------
# Committed fitted fixture (regenerate with generate_fitted_fixture.R)
# -----------------------------------------------------------------------------

load_fitted_fixture <- function() {
  model <- readRDS(FITTED_FIXTURE)
  built <- package_version(attr(model, "emc2_version"))
  have  <- utils::packageVersion("EMC2")
  if (!identical(unlist(built)[1:2], unlist(have)[1:2])) {
    testthat::skip(sprintf(
      "test_model_fitted.rds was built with EMC2 %s, installed is %s: regenerate it with __tests__/fixtures/generate_fitted_fixture.R",
      built, have))
  }
  model
}
