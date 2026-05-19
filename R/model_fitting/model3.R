#' PAF Model #3 [DEPRECATED - mechanistically identical to model4]:
#' v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc + StimulusAtLoc:SearchDifficulty
#' B ~ 1
#' sv ~ StimulusAtLoc
#' A ~ 1 ; t0 ~ 1
#'
#' NOTE: The interaction-only term StimulusAtLoc:SearchDifficulty forces EMC2 to
#' estimate v_StimulusAtLocT:SearchDifficultyMIXED and v_StimulusAtLocT:SearchDifficultyDIFFICULT
#' (the T-baseline interaction parameters), which are mechanistically identical to
#' model4's main-effect parameters v_SearchDifficultyMIXED and v_SearchDifficultyDIFFICULT.
#' Retained for reference; do not use in the primary analysis.

library(EMC2)

local({
  root <- Sys.getenv("PAF_REPO_ROOT", unset = "")
  if (nzchar(root)) source(file.path(root, "R", "model_fitting", "helpers", "model.R"))
  else              source("R/model_fitting/helpers/build_model.R")
})


MODEL_NAME <- "model3"

build_model <- function(data, n_chains = 3) {
  build_lba_model(
    data      = data,
    n_chains  = n_chains,
    v_formula = v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc + StimulusAtLoc:SearchDifficulty,
    B_formula = B ~ 1,
    extra_mu  = c("v_StimulusAtLocD:SearchDifficultyMIXED"     = V_STIM_D_SEARCH_MIX_MU,
                  "v_StimulusAtLocD:SearchDifficultyDIFFICULT" = V_STIM_D_SEARCH_DIF_MU,
                  "v_StimulusAtLocE:SearchDifficultyMIXED"     = V_STIM_E_SEARCH_MIX_MU,
                  "v_StimulusAtLocE:SearchDifficultyDIFFICULT" = V_STIM_E_SEARCH_DIF_MU),
    extra_sd  = c("v_StimulusAtLocD:SearchDifficultyMIXED"     = V_STIM_D_SEARCH_MIX_SD,
                  "v_StimulusAtLocD:SearchDifficultyDIFFICULT" = V_STIM_D_SEARCH_DIF_SD,
                  "v_StimulusAtLocE:SearchDifficultyMIXED"     = V_STIM_E_SEARCH_MIX_SD,
                  "v_StimulusAtLocE:SearchDifficultyDIFFICULT" = V_STIM_E_SEARCH_DIF_SD)
  )
}
