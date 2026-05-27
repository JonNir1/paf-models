#' =============================================================================
#' LBA Model Construction
#'
#' Factory function for all PAF LBA model variants. Owns the shared boilerplate
#' (base priors, design, prior object, make_emc) common to all five variants.
#' Each modelN.R passes only what differs: the v and B formulas plus any
#' model-specific prior entries beyond the shared base.
#'
#' Fixed across all variants (never vary, so hardcoded here):
#'   sv ~ StimulusAtLoc,  A ~ 1,  t0 ~ 1
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/fit_config.R")        # transitively: utils.R -> config.R
source_root("R/helpers/data.R")          # transitively: utils.R -> logging.R


# -------------------------
#' Factory for all PAF LBA model variants.
#'
#' Owns the shared boilerplate (base priors, design, prior object, make_emc).
#' Each modelN.R passes only what differs: the v and B formulas plus any
#' model-specific prior entries beyond the shared base.
#'
#' Fixed across all variants (never vary, so hardcoded here):
#'   sv ~ StimulusAtLoc,  A ~ 1,  t0 ~ 1
#'
#' @param data       Data frame returned by filter_data().
#' @param v_formula  Formula object for drift rate, e.g.
#'                   `v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc`.
#' @param B_formula  Formula object for threshold, e.g. `B ~ 1` or
#'                   `B ~ SearchDifficulty`.
#' @param extra_mu   Named numeric vector of prior means for model-specific
#'                   parameters (appended to the shared base). Default `c()`.
#' @param extra_sd   Named numeric vector of prior SDs, parallel to `extra_mu`.
#' @param n_chains   Passed to make_emc(). Default 3.
#' @return An emc object ready for fit() / run_emc().
build_lba_model <- function(data,
                            v_formula,
                            B_formula,
                            extra_mu  = c(),
                            extra_sd  = c(),
                            n_chains  = 3) {

  library(EMC2)

  # --- Base priors (shared by all model variants) ---
  base_mu <- c(
    v                     = V_BASELINE_MU,
    v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_MU,
    v_CueAtLocSMALL       = V_CUE_S_MU,
    v_CueAtLocMEDIUM      = V_CUE_M_MU,
    v_CueAtLocLARGE       = V_CUE_L_MU,
    v_StimulusAtLocD      = V_STIM_D_MU,
    v_StimulusAtLocE      = V_STIM_E_MU,
    sv_StimulusAtLocD     = SV_STIM_D_MU,
    sv_StimulusAtLocE     = SV_STIM_E_MU,
    B                     = B_BASELINE_MU,
    A                     = A_MU,
    t0                    = T0_MU
  )
  base_sd <- c(
    v                     = V_BASELINE_SD,
    v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_SD,
    v_CueAtLocSMALL       = V_CUE_S_SD,
    v_CueAtLocMEDIUM      = V_CUE_M_SD,
    v_CueAtLocLARGE       = V_CUE_L_SD,
    v_StimulusAtLocD      = V_STIM_D_SD,
    v_StimulusAtLocE      = V_STIM_E_SD,
    sv_StimulusAtLocD     = SV_STIM_D_SD,
    sv_StimulusAtLocE     = SV_STIM_E_SD,
    B                     = B_BASELINE_SD,
    A                     = A_SD,
    t0                    = T0_SD
  )

  mu    <- c(base_mu, extra_mu)
  Sigma <- c(base_sd, extra_sd)

  # --- Design ---
  LBA_design <- design(
    data      = data,
    model     = LBA,
    constants = CONSTANTS,
    functions = list(
      PrevTargetAtLoc  = PrevTargetAtLoc,
      CueAtLoc         = CueAtLoc,
      StimulusAtLoc    = StimulusAtLoc,
      SearchDifficulty = SearchDifficulty
    ),
    formula = list(
      v_formula,
      sv ~ StimulusAtLoc,
      B_formula,
      A  ~ 1,
      t0 ~ 1
    )
  )

  # --- Prior ---
  LBA_prior <- prior(LBA_design, type = "standard", mu_mean = mu, mu_sd = Sigma)

  # --- Model object ---
  make_emc(data, design = LBA_design, prior = LBA_prior, n_chains = n_chains)
}
