#' =============================================================================
#' pt_v: PrevTarget-locus family member, PrevTargetAtLoc on: v.
#' See R/fit/helpers/pt_family.R. MODEL_NAME gains a "_sd<scale>" suffix when the
#' PT_PRIOR_SD_SCALE env var is not 1 (prior-sensitivity refits; names stay unique).
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/pt_family.R")

MODEL_NAME <- paste0("pt_v", if (Sys.getenv("PT_PRIOR_SD_SCALE", "1") %in% c("", "1")) "" else paste0("_sd", Sys.getenv("PT_PRIOR_SD_SCALE")))

MODEL_DATA_ARGS <- list(difficulties = c("EASY", "DIFFICULT"))

# NA: no structural zeros in any family member, every parameter is identifiable.
STRUCTURAL_UNIDENTIFIABLE_PATTERN <- NA_character_

build_model <- function(data, n_chains) build_pt_model(data, n_chains, pt_on = c("v"))
