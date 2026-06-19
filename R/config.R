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


# --- Convergence thresholds (asymmetric; mu tighter than alpha) ---
# Cross-cutting analysis decision, used by BOTH the fitting layer (extend_model
# stop criteria, R/fit/helpers/fitting.R) and the evaluation layer (the step-2.9
# convergence verdict, R/eval/helpers/convergence.R). Applied to the $mu and
# $alpha blocks only; $sigma2 and $correlation are descriptive (not enforced).
MAX_RHAT_MU    <- 1.05;  MIN_ESS_MU    <- 500   # population params reported with CIs
MAX_RHAT_ALPHA <- 1.10;  MIN_ESS_ALPHA <- 400   # subject params feed OOD simulation


# --- Paths ---
CODE_DIR    <- "R"
DATA_DIR    <- "data"

OUTPUTS_DIR <- "outputs"
MODELS_DIR  <- file.path(OUTPUTS_DIR, "models")
EVAL_DIR    <- file.path(OUTPUTS_DIR, "evaluation")

MODELS_FIT_DIR      <- file.path(MODELS_DIR, "fit")            # output of the unified fit pipeline (fit_cloud.R / fit_to_convergence)
MODELS_RECOVERY_DIR <- file.path(MODELS_DIR, "fit_recovery")   # output of fit_recovery_cloud.R

# Path to the fitting-config file, used by log_config_variables() to snapshot
# the fitting params into each run's log.
FIT_CONFIG_FILE <- file.path(CODE_DIR, "fit", "fit_config.R")
