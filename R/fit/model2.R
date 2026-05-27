#' PAF Model #2:
#' v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc + SearchDifficulty
#' B ~ 1
#' sv ~ StimulusAtLoc
#' A ~ 1 ; t0 ~ 1

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/build_model.R")


MODEL_NAME <- "model2"

build_model <- function(data, n_chains = 3) {
  build_lba_model(
    data      = data,
    n_chains  = n_chains,
    v_formula = v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc + SearchDifficulty,
    B_formula = B ~ 1,
    extra_mu  = c(v_SearchDifficultyMIXED     = V_SEARCH_MIX_MU,
                  v_SearchDifficultyDIFFICULT = V_SEARCH_DIF_MU),
    extra_sd  = c(v_SearchDifficultyMIXED     = V_SEARCH_MIX_SD,
                  v_SearchDifficultyDIFFICULT = V_SEARCH_DIF_SD)
  )
}
