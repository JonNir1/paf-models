#' Set global settings shared across all models


# --- Randomness ---
RNG_KIND <- "L'Ecuyer-CMRG"
RNG_SEED <- 42


# --- Paths ---
CODE_DIR <- "R"
RESULTS_DIR <- "Results"

DATA_DIR <- "data"
DATA_FILE <- file.path(DATA_DIR, "emc2_design_matrix.csv")

MODELS_DIR         <- "emc2_models"
MODELS_INITIAL_DIR <- file.path(MODELS_DIR, "fit_initial")   # output of fit_initial.R
MODELS_EXTEND_DIR  <- file.path(MODELS_DIR, "fit_extend")    # output of fit_extend_*.R

CONFIG_FILE <- file.path(CODE_DIR, "config.R")  # used by log_config_variables()


# --- Data Filtering ---
MIN_SACCADE_CUTOFF <- 0.23
MAX_SACCADE_CUTOFF <- 1.0
ALLOW_TARGET_REPEAT <- TRUE


# --- Fitting Params ---
N_CHAINS <- 3   # MCMC chains per model; baked into the emc object at make_emc() time.
                # Parallelism (cores_for_chains, cores_per_chain) is auto-detected at
                # runtime by get_core_args() in helpers.R — no manual core config needed.

# criteria for stopping the "sample" stage of model-fitting
MIN_NUM_SAMPLES   <- 1000   # iterations run by fit_initial.R
MIN_TOTAL_SAMPLES <- 3000L  # extend keeps running until total iters >= this (even if Rhat/ESS met)
MAX_TRIES <- 20   # number of times to check if "stop criteria" are met
STEP_SIZE <- 100  # number of iterations between "stop criteria" checks
SAVE_EVERY <- 2L  # checkpoint every N tries (2 tries x 100 iters = 200-iter checkpoints)

# Asymmetric convergence thresholds applied to $mu and $alpha only.
# $sigma2 and $correlation are descriptive (not enforced) - see CLAUDE.md "Analysis workflow".
MAX_RHAT_MU    <- 1.05;  MIN_ESS_MU    <- 500   # tighter Rhat: population params reported with CIs
MAX_RHAT_ALPHA <- 1.10;  MIN_ESS_ALPHA <- 400   # EMC2-default-aligned: subject params feed OOD simulation


# ----------------------------
# --- Prior Specifications ---
CONSTANTS <- c(sv=log(1))

# --- V Priors ---
V_BASELINE_MU <- 2; V_BASELINE_SD <- 2
V_PREVTAR_TRUE_MU <- 0.75; V_PREVTAR_TRUE_SD <- 1
V_CUE_S_MU <- 0.1; V_CUE_S_SD <- 1
V_CUE_M_MU <- 0.5; V_CUE_M_SD <- 1
V_CUE_L_MU <- 1; V_CUE_L_SD <- 1
V_STIM_D_MU <- -0.5; V_STIM_D_SD <- 1
V_STIM_E_MU <- -1.5; V_STIM_E_SD <- 1
V_SEARCH_MIX_MU <- -0.1; V_SEARCH_MIX_SD <- 1
V_SEARCH_DIF_MU <- -0.2; V_SEARCH_DIF_SD <- 1

V_STIM_D_SEARCH_MIX_MU <- 0; V_STIM_D_SEARCH_MIX_SD <- 0.5
V_STIM_D_SEARCH_DIF_MU <- 0.1; V_STIM_D_SEARCH_DIF_SD <- 0.5
V_STIM_E_SEARCH_MIX_MU <- 0.1; V_STIM_E_SEARCH_MIX_SD <- 0.5
V_STIM_E_SEARCH_DIF_MU <- 0; V_STIM_E_SEARCH_DIF_SD <- 0.5

# --- SV Priors ---
# SV_BASELINE is used as scaling constant (sv=log(1))
SV_STIM_D_MU <- log(1); SV_STIM_D_SD <- 1
SV_STIM_E_MU <- log(1); SV_STIM_E_SD <- 1

# --- B Priors ---
B_BASELINE_MU <- log(1); B_BASELINE_SD <- 1
B_SEARCH_MIX_MU <- log(1.5); B_SEARCH_MIX_SD <- 1
B_SEARCH_DIF_MU <- log(2); B_SEARCH_DIF_SD <- 1

# --- A and T0 Priors --- 
A_MU = log(0.5); A_SD = 1
T0_MU = log(0.5 * MIN_SACCADE_CUTOFF); T0_SD = 1    # use the saccade cutoff as initial t0 estimate
