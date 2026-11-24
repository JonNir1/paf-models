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
emc_compare             <- function(...) EMC2::compare(...)
emc_recovery            <- function(...) EMC2::recovery(...)
emc_bridge_sampling     <- function(...) EMC2::run_bridge_sampling(...)
emc_version             <- function() as.character(utils::packageVersion("EMC2"))


#' Rhat (row 1) or ESS (row 2) values of one EMC2 check() block, as one vector.
#'
#' Per block `g`, check() holds a 2-row matrix (row 1 = Rhat, row 2 = ESS;
#' columns = parameters), either directly (`chk[[g]]`) or nested
#' (`chk[[g]][[g]]`). For `alpha` it holds a per-subject list of such matrices,
#' pooled here into one vector. Fails loudly on any other layout.
#'
#' @param chk     Object returned by check().
#' @param group   One of "mu", "sigma2", "alpha", "correlation".
#' @param row_idx 1 for Rhat, 2 for ESS.
#' @return Numeric vector (NAs kept).
check_block_values <- function(chk, group, row_idx) {
  blk <- chk[[group]]
  if (is.null(blk)) stop(sprintf("check() returned no '%s' block.", group))

  mats <- if (group == "alpha") blk else list(if (is.matrix(blk)) blk else blk[[group]])
  unlist(lapply(mats, function(m) {
    if (!is.matrix(m) || nrow(m) < row_idx) {
      stop(sprintf("Unexpected check() layout for block '%s' (expected >= %d rows).",
                   group, row_idx))
    }
    m[row_idx, ]
  }))
}
