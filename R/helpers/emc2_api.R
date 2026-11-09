#' =============================================================================
#' EMC2 API Seam
#'
#' Thin namespaced wrappers around every EMC2 entry point the pipeline's
#' orchestration calls. They let L1 tests replace EMC2 with
#' local_mocked_bindings(..., .env = globalenv()) on machines without EMC2, and
#' remove the need for call-time library(EMC2).
#' =============================================================================

emc_fit                 <- function(...) EMC2::fit(...)
emc_run                 <- function(...) EMC2::run_emc(...)
emc_check               <- function(...) EMC2::check(...)
emc_get_pars            <- function(...) EMC2::get_pars(...)
emc_make_data           <- function(...) EMC2::make_data(...)
emc_make_random_effects <- function(...) EMC2::make_random_effects(...)
emc_design              <- function(..., model = EMC2::LBA) EMC2::design(..., model = model)
emc_prior               <- function(...) EMC2::prior(...)
emc_make_emc            <- function(...) EMC2::make_emc(...)
emc_sampled_pars        <- function(...) EMC2::sampled_pars(...)
