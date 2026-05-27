#' PAF Model #1:
#' v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc
#' B ~ SearchDifficulty
#' sv ~ StimulusAtLoc
#' A ~ 1 ; t0 ~ 1

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/build_model.R")


MODEL_NAME <- "model1"

build_model <- function(data, n_chains = 3) {
  build_lba_model(
    data      = data,
    n_chains  = n_chains,
    v_formula = v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc,
    B_formula = B ~ SearchDifficulty,
    extra_mu  = c(B_SearchDifficultyMIXED     = B_SEARCH_MIX_MU,
                  B_SearchDifficultyDIFFICULT = B_SEARCH_DIF_MU),
    extra_sd  = c(B_SearchDifficultyMIXED     = B_SEARCH_MIX_SD,
                  B_SearchDifficultyDIFFICULT = B_SEARCH_DIF_SD)
  )
}
