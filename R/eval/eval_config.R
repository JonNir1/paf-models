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


#' Discover fitted-model names in a directory (the active model set).
#'
#' The unified pipeline writes `YYMMDD_<name>.rds`; the legacy `_extended`
#' suffix is also tolerated. Returns the unique bare model names, sorted. Eval
#' drivers default their MODEL_NAMES to this so the analysis adapts to whatever
#' model family currently lives in the fit directory -- no hardcoded list.
#'
#' @param dir_path Directory to scan (default: MODELS_FIT_DIR).
#' @return Character vector of unique model names (possibly empty).
discover_model_names <- function(dir_path = MODELS_FIT_DIR) {
  if (!dir.exists(dir_path)) return(character(0))
  files <- list.files(dir_path, pattern = "^[0-9]{6}_.*\\.rds$")
  names <- sub("^[0-9]{6}_", "", tools::file_path_sans_ext(files))
  names <- sub("(_extended)+$", "", names)
  sort(unique(names))
}


#' Assign a stable plotting colour to each model name from a base palette.
#' Replaces the old model1/2/4/5-specific named vector so plots work for any
#' model family. Recycles the palette if there are more models than colours.
#' @param model_names Character vector of model names.
#' @return Named character vector (names = model_names, values = hex colours).
model_colors <- function(model_names) {
  palette <- c("#2c7fb8", "#31a354", "#d95f02", "#7570b3",
               "#e7298a", "#66a61e", "#e6ab02", "#a6761d")
  cols <- palette[(seq_along(model_names) - 1L) %% length(palette) + 1L]
  stats::setNames(cols, model_names)
}


# --- Structurally-unidentifiable parameters (design partial-nesting) ---
# `StimulusAtLoc` (the distractor type at an accumulator's location) and
# `SearchDifficulty` (a trial-level property of the whole 4-location display) are
# PARTIALLY NESTED, not crossed:
#   - an easy distractor never appears on an all-difficult trial  => E x DIFFICULT empty
#   - a difficult distractor never appears on an all-easy trial   => D x EASY  empty
# In models carrying the v ~ StimulusAtLoc * SearchDifficulty interaction (models
# 4 and 5) this makes the StimulusAtLoc-by-SearchDifficulty interaction block
# unidentifiable (v_StimulusAtLocE:SearchDifficultyDIFFICULT is a pure structural
# zero), and aliases the StimulusAtLoc main effects (the empty D x EASY baseline
# cell). Recovery is therefore reported both for the FULL parameter set and for the
# "core" subspace with this block removed (step 2.9). The pattern below matches the
# StimulusAtLoc main effects and their SearchDifficulty interactions.
# NOTE: this is a known design limitation flagged for the PI at 2.9; it is NOT
# silently dropped from the fitted models.
# MODEL-FAMILY-SPECIFIC: this regex matches the retired model1-5 design (preserved
# on the `analysis1` branch). Revise it to the structural zeros of the new model
# family before running recovery eval; set to a never-matching pattern if none.
STRUCTURAL_UNIDENTIFIABLE_PATTERN <-
  "^v_StimulusAtLoc[DE](:SearchDifficulty(MIXED|DIFFICULT))?$"


# --- Step 4: PPC config ---
PPC_EVAL_DIR <- file.path(EVAL_DIR, "ppc")
PPC_N_DRAWS  <- 500L    # posterior predictive draws per model
PPC_AD_ALPHA <- 0.05    # FDR-adjusted significance threshold for Anderson-Darling test
PPC_MODELS_DIR <- file.path(MODELS_DIR, "fit_ppc")  # where fit_ppc_cloud.R writes .rds files


# --- Step 3: LOO / WAIC thresholds (loo package / Vehtari et al. 2017 convention) ---
PARETO_K_THRESHOLD <- 0.7    # k > 0.7 = "bad"; k > 0.5 = "ok but cautious"
PARETO_K_BAD_FRAC  <- 0.10   # >10% bad k triggers PI flag at step 3.9
LOO_DIR <- file.path(EVAL_DIR, "loo")
