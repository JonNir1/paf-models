#' =============================================================================
#' Project-level config. Sourced by EVERY script (directly or via fit_config.R /
#' eval_config.R). Holds only cross-cutting constants:
#'   - RNG settings
#'   - Data filter cutoffs
#'   - Input/output directory paths
#'
#' Fitting-specific knobs (priors, N_CHAINS, convergence thresholds, recovery
#' params) live in R/fit/fit_config.R.
#' Evaluation-specific knobs (GoF thresholds, plot params) live in R/eval/eval_config.R.
#' =============================================================================


# --- Randomness ---
RNG_KIND <- "L'Ecuyer-CMRG"
RNG_SEED <- 42


# --- Data Filtering ---
MIN_SACCADE_CUTOFF  <- 0.23
MAX_SACCADE_CUTOFF  <- 1.0
ALLOW_TARGET_REPEAT <- TRUE


# --- Paths ---
CODE_DIR    <- "R"
DATA_DIR    <- "data"
DATA_FILE   <- file.path(DATA_DIR, "emc2_design_matrix.csv")

OUTPUTS_DIR <- "outputs"
MODELS_DIR  <- file.path(OUTPUTS_DIR, "models")
EVAL_DIR    <- file.path(OUTPUTS_DIR, "evaluation")

MODELS_INITIAL_DIR  <- file.path(MODELS_DIR, "fit_initial")    # output of fit_initial.R
MODELS_EXTEND_DIR   <- file.path(MODELS_DIR, "fit_extend")     # output of fit_extend_*.R
MODELS_RECOVERY_DIR <- file.path(MODELS_DIR, "fit_recovery")   # output of fit_recovery_cloud.R

# Path to the fitting-config file, used by log_config_variables() to snapshot
# the fitting params into each run's log.
FIT_CONFIG_FILE <- file.path(CODE_DIR, "fit", "fit_config.R")
