#' =============================================================================
#' Evaluation config: GoF thresholds, plot parameters, etc.
#'
#' Sourced by every script under R/eval/. Pulls in the project-level R/config.R
#' first for RNG, paths, and data filters.
#'
#' Currently minimal -- placeholder for step 3 (LOO/WAIC/BPIC) thresholds.
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/config.R")

# Subdir under EVAL_DIR for per-step evaluation outputs.
RECOVERY_EVAL_DIR <- file.path(EVAL_DIR, "parameter_recovery")
