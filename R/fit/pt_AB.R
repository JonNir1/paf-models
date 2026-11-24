#' =============================================================================
#' pt_AB: PrevTarget-locus family member, PrevTargetAtLoc on: A, B.
#' See R/fit/helpers/pt_family.R. MODEL_NAME gains a "_sd<scale>" suffix when the
#' PT_PRIOR_SD_SCALE env var is not 1 (prior-sensitivity refits; names stay unique).
#' The scale is normalised like pt_prior_sd_scale() (it cannot be called here: the
#' declaration is read without executing the script); same expression in all 8 scripts.
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/pt_family.R")

MODEL_NAME <- paste0("pt_AB", local({ s <- suppressWarnings(as.numeric(sub("^$", "1", trimws(Sys.getenv("PT_PRIOR_SD_SCALE", "1"))))); if (!is.finite(s) || s <= 0) stop("PT_PRIOR_SD_SCALE must be a positive number"); if (s == 1) "" else paste0("_sd", format(s, scientific = FALSE)) }))

MODEL_DATA_ARGS <- list(difficulties = c("EASY", "DIFFICULT"))

# NA: no structural zeros in any family member, every parameter is identifiable.
STRUCTURAL_UNIDENTIFIABLE_PATTERN <- NA_character_

build_model <- function(data, n_chains) build_pt_model(data, n_chains, pt_on = c("A", "B"))
