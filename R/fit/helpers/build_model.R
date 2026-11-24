#' =============================================================================
#' LBA Model Construction
#'
#' Factory function for all PAF LBA model variants. Owns the shared boilerplate
#' (design, prior object, make_emc). Each model script passes only what differs:
#' the parameter formulas plus any model-specific prior entries.
#'
#' Prior means/SDs for the intercepts (v, B, A, t0) come from the master
#' PRIOR_MU/PRIOR_SD tables in fit_config.R; every effect prior is supplied by
#' the model via extra_mu/extra_sd. t0 ~ 1 is the only formula fixed here (v, sv,
#' B are caller-supplied, A defaults to A ~ 1).
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/fit_config.R")        # transitively: utils.R -> config.R
source_root("R/helpers/data.R")          # transitively: utils.R -> logging.R
source_root("R/helpers/emc2_api.R")      # emc_* wrappers


# All EMC2 factor closures from R/helpers/data.R (default `functions` of build_lba_model()).
LBA_FUNCTIONS <- list(
  PrevTargetAtLoc  = PrevTargetAtLoc,
  CueAtLoc         = CueAtLoc,
  StimulusAtLoc    = StimulusAtLoc,
  TargetAtLoc      = TargetAtLoc,
  SearchDifficulty = SearchDifficulty
)


# -------------------------
#' Factory for all PAF LBA model variants.
#'
#' Owns the shared boilerplate (design, prior object, make_emc). Each model
#' script passes only what differs: the parameter formulas plus any
#' model-specific prior entries beyond the shared master table.
#'
#' Prior means/SDs are NOT hardcoded here: they are selected from the master
#' PRIOR_MU/PRIOR_SD tables in fit_config.R (intercepts only) merged with
#' extra_mu/extra_sd, by matching the design's `sampled_pars()`. A sampled
#' parameter lacking a mean or an SD in the merged table is a hard error.
#'
#' @param data       Data frame returned by filter_data().
#' @param v_formula  Formula object for drift rate, e.g.
#'                   `v ~ TargetAtLoc * SearchDifficulty`.
#' @param B_formula  Formula object for threshold, e.g. `B ~ 1` or
#'                   `B ~ PrevTargetAtLoc`.
#' @param A_formula  Formula object for start-point bound. Default `A ~ 1`.
#' @param sv_formula Formula object for drift SD, e.g. `sv ~ TargetAtLoc`.
#'                   Required (no default).
#' @param extra_mu   Named numeric vector of prior means for model-specific
#'                   parameters; overrides/extends the master table. Default `c()`.
#' @param extra_sd   Named numeric vector of prior SDs, parallel to `extra_mu`.
#' @param n_chains   Passed to make_emc(). Default 3.
#' @param functions  Named list of the factor closures passed to design();
#'                   default all of them (see `LBA_FUNCTIONS`). Pass only the
#'                   closures the formulas use to cut design() time.
#' @return An emc object ready for fit() / run_emc().
build_lba_model <- function(data,
                            v_formula,
                            B_formula,
                            sv_formula,
                            A_formula = A ~ 1,
                            extra_mu  = c(),
                            extra_sd  = c(),
                            n_chains  = 3,
                            functions = LBA_FUNCTIONS) {

  # --- Design ---
  LBA_design <- emc_design(
    data      = data,
    constants = CONSTANTS,
    functions = functions,
    formula = list(
      v_formula,
      sv_formula,
      B_formula,
      A_formula,
      t0 ~ 1
    )
  )

  # --- Priors: select from the master table for exactly the sampled params ---
  # extra_mu/extra_sd override existing names and add model-specific ones.
  master_mu <- PRIOR_MU; master_mu[names(extra_mu)] <- extra_mu
  master_sd <- PRIOR_SD; master_sd[names(extra_sd)] <- extra_sd

  sp_names <- names(emc_sampled_pars(LBA_design))
  missing  <- setdiff(sp_names, intersect(names(master_mu), names(master_sd)))
  if (length(missing) > 0) {
    stop(sprintf(
      "No prior defined for sampled parameter(s): %s. Add them to PRIOR_MU/PRIOR_SD in fit_config.R or pass via extra_mu/extra_sd.",
      paste(missing, collapse = ", ")
    ))
  }
  mu    <- master_mu[sp_names]
  Sigma <- master_sd[sp_names]

  # --- Prior ---
  LBA_prior <- emc_prior(LBA_design, type = "standard", mu_mean = mu, mu_sd = Sigma)

  # --- Model object ---
  emc_make_emc(data, design = LBA_design, prior = LBA_prior, n_chains = n_chains)
}
