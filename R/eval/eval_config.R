#' =============================================================================
#' Evaluation config: GoF thresholds, plot parameters, etc.
#'
#' Sourced by every script under R/eval/. Pulls in the project-level R/config.R
#' first for RNG, paths, and data filters.
#'
#' Holds the PPC (step 4) and LOO/WAIC (step 3) settings and thresholds.
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/config.R")
source_root("R/eval/helpers/io.R")

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
  sort(unique(model_name_from_rds(files)))
}


#' Assign a stable plotting colour to each model name from a base palette.
#' Generic over the model family (no fixed model names). Recycles the palette if there are more models than colours.
#' @param model_names Character vector of model names.
#' @return Named character vector (names = model_names, values = hex colours).
model_colors <- function(model_names) {
  palette <- c("#2c7fb8", "#31a354", "#d95f02", "#7570b3",
               "#e7298a", "#66a61e", "#e6ab02", "#a6761d")
  cols <- palette[(seq_along(model_names) - 1L) %% length(palette) + 1L]
  stats::setNames(cols, model_names)
}


# Directory of the model scripts (R/fit/); each is found by its declared MODEL_NAME and declares its own
# STRUCTURAL_UNIDENTIFIABLE_PATTERN. A caller may pre-set MODEL_SCRIPT_DIR.
if (!exists("MODEL_SCRIPT_DIR")) MODEL_SCRIPT_DIR <- file.path(CODE_DIR, "fit")


# --- Step 4: PPC config ---
PPC_EVAL_DIR <- file.path(EVAL_DIR, "ppc")
PPC_N_DRAWS  <- 500L    # posterior predictive draws per model
PPC_KS_ALPHA <- 0.05    # FDR-adjusted significance threshold for the per-subject KS test
PPC_MODELS_DIR <- file.path(MODELS_DIR, "fit_ppc")  # where fit_ppc_cloud.R writes .rds files
# Condition cells of the PPC tables: one cell per combination of these columns (the
# figures' x variables are all of them except `experiment`). Pre-settable by the caller.
# analysis2: target-repeat (target at the previous target location) x difficulty; cue is not modelled.
if (!exists("PPC_GROUP_VARS")) PPC_GROUP_VARS <- c("experiment", "search_difficulty", "is_target_repeated")


# --- Step 3: LOO / WAIC thresholds (loo package / Vehtari et al. 2017 convention) ---
PARETO_K_THRESHOLD <- 0.7    # k > 0.7 = "bad"; k > 0.5 = "ok but cautious"
PARETO_K_BAD_FRAC  <- 0.10   # >10% bad k triggers PI flag at step 3.9
LOO_DIR <- file.path(EVAL_DIR, "loo")


# --- Bayes factors (bridge sampling) ---
if (!exists("BF_REPS")) BF_REPS <- 5L                    # bridge-sampling repetitions per fit (spread = stability); pre-settable
BF_DIR        <- file.path(EVAL_DIR, "bayes_factors")     # BF tables
MODELS_BF_DIR <- file.path(MODELS_DIR, "fit_bf")          # per-fit MLL files written by fit_bf_cloud.R

# --- Model recovery (generating x selected model) ---
MODEL_RECOVERY_EVAL_DIR <- file.path(EVAL_DIR, "model_recovery")
