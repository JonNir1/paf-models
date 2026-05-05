#' PAF Model #2:
#' v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc + SearchDifficulty
#' B ~ 1
#' sv ~ StimulusAtLoc
#' A ~ 1 ; t0 ~ 1

library(EMC2)

source("R/config.R")
source(file.path(CODE_DIR, "model_fitting", "helpers.R"))


MODEL_NAME <- "model2"

# --- Priors ---
mu <- c(
  
  # v (drift rates) is on the real line
  v = V_BASELINE_MU,
  v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_MU,
  v_CueAtLocSMALL = V_CUE_S_MU, v_CueAtLocMEDIUM = V_CUE_M_MU, v_CueAtLocLARGE = V_CUE_L_MU,
  
  v_StimulusAtLocD = V_STIM_D_MU, v_StimulusAtLocE = V_STIM_E_MU,
  
  v_SearchDifficultyMIXED = V_SEARCH_MIX_MU, v_SearchDifficultyDIFFICULT = V_SEARCH_DIF_MU,

  # sv is in log scale
  sv_StimulusAtLocD = SV_STIM_D_MU, sv_StimulusAtLocE = SV_STIM_E_MU,
  
  # B, A, t0 are in log scale
  B = B_BASELINE_MU,
  A = A_MU, t0 = T0_MU
)

Sigma <- c(
  
  # v (drift rates) is on the real line
  v = V_BASELINE_SD,
  v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_SD,
  v_CueAtLocSMALL = V_CUE_S_SD, v_CueAtLocMEDIUM = V_CUE_M_SD, v_CueAtLocLARGE = V_CUE_L_SD,
  
  v_StimulusAtLocD = V_STIM_D_SD, v_StimulusAtLocE = V_STIM_E_SD,
  
  v_SearchDifficultyMIXED = V_SEARCH_MIX_SD, v_SearchDifficultyDIFFICULT = V_SEARCH_DIF_SD,
  
  # sv is in log scale
  sv_StimulusAtLocD = SV_STIM_D_SD, sv_StimulusAtLocE = SV_STIM_E_SD,
  
  # B, A, t0 are in log scale
  B = B_BASELINE_SD,
  A = A_SD, t0 = T0_SD
)


build_model <- function(data) {
  
  # Build EMC2::Design object
  LBA_design <- design(
    data=data,
    model=LBA,
    constants=CONSTANTS,
    functions=list(
      PrevTargetAtLoc=PrevTargetAtLoc,
      CueAtLoc=CueAtLoc,
      StimulusAtLoc=StimulusAtLoc,
      SearchDifficulty=SearchDifficulty
    ),
    # contrasts=list(),
    formula=list(
      v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc + SearchDifficulty,
      sv ~ StimulusAtLoc,
      B ~ 1,
      A ~ 1,
      t0 ~ 1
    ),
  )
  # mapped_pars(LBA_design)
  
  # Build EMC2::Prior object
  LBA_prior <- prior(
    LBA_design,
    type = 'standard',
    mu_mean=mu,
    mu_sd=Sigma
  )
  # plot(LBA_prior)
  
  # Build EMC2::Model object
  LBA_model <- make_emc(data, design = LBA_design, prior = LBA_prior)
  return(LBA_model)
}
