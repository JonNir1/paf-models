#' =============================================================================
#' Fitting config: priors, MCMC params, convergence thresholds, recovery params.
#'
#' Sourced by every script under R/fit/ (and by scripts that fit fresh models,
#' e.g. fit_recovery_cloud.R). Pulls in the project-level R/config.R first for
#' RNG, paths, and data filters.
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/config.R")

# ============================================================================
# Prior specifications
# ============================================================================

# --- Identifiability anchor for the LBA ---
# REMOVING or CHANGING this will silently make the model non-identifiable.
CONSTANTS <- c(sv = log(1))

# --- V (drift rate) ---
V_BASELINE_MU      <- 2;     V_BASELINE_SD      <- 2
V_PREVTAR_TRUE_MU  <- 0.75;  V_PREVTAR_TRUE_SD  <- 1
V_CUE_S_MU         <- 0.1;   V_CUE_S_SD         <- 1
V_CUE_M_MU         <- 0.5;   V_CUE_M_SD         <- 1
V_CUE_L_MU         <- 1;     V_CUE_L_SD         <- 1
V_STIM_D_MU        <- -0.5;  V_STIM_D_SD        <- 1
V_STIM_E_MU        <- -1.5;  V_STIM_E_SD        <- 1
V_SEARCH_MIX_MU    <- -0.1;  V_SEARCH_MIX_SD    <- 1
V_SEARCH_DIF_MU    <- -0.2;  V_SEARCH_DIF_SD    <- 1

V_STIM_D_SEARCH_MIX_MU <- 0;    V_STIM_D_SEARCH_MIX_SD <- 0.5
V_STIM_D_SEARCH_DIF_MU <- 0.1;  V_STIM_D_SEARCH_DIF_SD <- 0.5
V_STIM_E_SEARCH_MIX_MU <- 0.1;  V_STIM_E_SEARCH_MIX_SD <- 0.5
V_STIM_E_SEARCH_DIF_MU <- 0;    V_STIM_E_SEARCH_DIF_SD <- 0.5


# --- SV (between-trial variability in v); SV_BASELINE is the sv=log(1) anchor ---
SV_STIM_D_MU <- log(1);  SV_STIM_D_SD <- 1
SV_STIM_E_MU <- log(1);  SV_STIM_E_SD <- 1


# --- B (threshold) ---
B_BASELINE_MU    <- log(1);    B_BASELINE_SD    <- 1
B_SEARCH_MIX_MU  <- log(1.5);  B_SEARCH_MIX_SD  <- 1
B_SEARCH_DIF_MU  <- log(2);    B_SEARCH_DIF_SD  <- 1


# --- A (start-point variability) and t0 (non-decision time) ---
A_MU  <- log(0.5);                       A_SD  <- 1
T0_MU <- log(0.5 * MIN_SACCADE_CUTOFF);  T0_SD <- 1   # use saccade cutoff as initial t0 estimate


# ============================================================================
# Model Fitting
# Parameters for fit_initial and fit_extend
# ============================================================================

# --- MCMC chains ---
# Number of MCMC chains baked into each emc object at make_emc() time.
# Cannot be changed after fitting. Parallelism (cores_for_chains, cores_per_chain)
# is auto-detected at runtime by get_core_args() in helpers/fitting.R.
N_CHAINS <- 3

# --- Fitting / extending ---
INITIAL_FIT_SAMPLES  <- 1000    # iterations run by fit_initial.R
EXTENDED_FIT_SAMPLES <- 3000L   # extend keeps running until total iters >= this (even if Rhat/ESS met)
MAX_TRIES  <- 20    # number of times to check whether stop criteria are met
STEP_SIZE  <- 200   # iterations between stop-criteria checks
SAVE_EVERY <- 2L    # checkpoint every N tries (2 x 200 iters = 400-iter checkpoints)


# --- Convergence thresholds (asymmetric; mu tighter than alpha) ---
# RELOCATED to R/config.R (sourced above) so the evaluation layer can reuse them
# as a single source of truth: MAX_RHAT_MU, MIN_ESS_MU, MAX_RHAT_ALPHA, MIN_ESS_ALPHA.

# ============================================================================
# Parameter Recovery
# Replicating Strickland et al. (2026) Supplementary methodology.
# Relaxed thresholds vs. real fits: recovery is diagnostic, not for inference.
# ============================================================================
RECOVERY_FIT_SAMPLES <- 1000L   # sample floor (vs. 3000 for real fits)
RECOVERY_BASE_SEED   <- 100L    # reproducible per-sim seeds: BASE + sim_index
MAX_RHAT_MU_RECOVERY    <- 1.10 ;   MIN_ESS_MU_RECOVERY     <- 300
MAX_RHAT_ALPHA_RECOVERY <- 1.10 ;   MIN_ESS_ALPHA_RECOVERY  <- 300
MAX_TRIES_RECOVERY      <- 10   ;   STEP_SIZE_RECOVERY      <- 100
