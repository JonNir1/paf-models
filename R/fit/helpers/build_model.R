#' =============================================================================
#' LBA Model Construction
#'
#' Factory function for all PAF LBA model variants. Owns the shared boilerplate
#' (design, prior object, make_emc). Each model script passes only what differs:
#' the parameter formulas plus any model-specific prior entries.
#'
#' Prior means/SDs are selected from the master PRIOR_MU/PRIOR_SD tables in
#' fit_config.R by matching the design's sampled_pars(); t0 ~ 1 is the only
#' formula fixed here (A, sv, B, v are all caller-supplied, with defaults
#' A ~ 1 and sv ~ StimulusAtLoc).
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/fit_config.R")        # transitively: utils.R -> config.R
source_root("R/helpers/data.R")          # transitively: utils.R -> logging.R


# -------------------------
#' Factory for all PAF LBA model variants.
#'
#' Owns the shared boilerplate (design, prior object, make_emc). Each model
#' script passes only what differs: the parameter formulas plus any
#' model-specific prior entries beyond the shared master table.
#'
#' Prior means/SDs are NOT hardcoded here: they are selected from the master
#' PRIOR_MU/PRIOR_SD tables in fit_config.R by matching the design's
#' `sampled_pars()`. A sampled parameter with no entry in the master table (and
#' not supplied via extra_mu/extra_sd) is a hard error -- add it to the table.
#'
#' @param data       Data frame returned by filter_data().
#' @param v_formula  Formula object for drift rate, e.g.
#'                   `v ~ TargetAtLoc * SearchDifficulty`.
#' @param B_formula  Formula object for threshold, e.g. `B ~ 1` or
#'                   `B ~ PrevTargetAtLoc`.
#' @param A_formula  Formula object for start-point bound. Default `A ~ 1`.
#' @param sv_formula Formula object for drift SD. Default `sv ~ StimulusAtLoc`.
#' @param extra_mu   Named numeric vector of prior means for model-specific
#'                   parameters; overrides/extends the master table. Default `c()`.
#' @param extra_sd   Named numeric vector of prior SDs, parallel to `extra_mu`.
#' @param n_chains   Passed to make_emc(). Default 3.
#' @return An emc object ready for fit() / run_emc().
build_lba_model <- function(data,
                            v_formula,
                            B_formula,
                            A_formula  = A ~ 1,
                            sv_formula = sv ~ StimulusAtLoc,
                            extra_mu   = c(),
                            extra_sd   = c(),
                            n_chains   = 3) {

  library(EMC2)

  # --- Design ---
  LBA_design <- design(
    data      = data,
    model     = LBA,
    constants = CONSTANTS,
    functions = list(
      PrevTargetAtLoc  = PrevTargetAtLoc,
      CueAtLoc         = CueAtLoc,
      StimulusAtLoc    = StimulusAtLoc,
      TargetAtLoc      = TargetAtLoc,
      SearchDifficulty = SearchDifficulty
    ),
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

  sp_names <- names(sampled_pars(LBA_design))
  missing  <- setdiff(sp_names, names(master_mu))
  if (length(missing) > 0) {
    stop(sprintf(
      "No prior defined for sampled parameter(s): %s. Add them to PRIOR_MU/PRIOR_SD in fit_config.R or pass via extra_mu/extra_sd.",
      paste(missing, collapse = ", ")
    ))
  }
  mu    <- master_mu[sp_names]
  Sigma <- master_sd[sp_names]

  # --- Prior ---
  LBA_prior <- prior(LBA_design, type = "standard", mu_mean = mu, mu_sd = Sigma)

  # --- Model object ---
  make_emc(data, design = LBA_design, prior = LBA_prior, n_chains = n_chains)
}
