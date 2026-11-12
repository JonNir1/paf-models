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
