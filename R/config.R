#' Set global settings shared across all models


# --- Randomness ---
RNG_KIND <- "L'Ecuyer-CMRG"
RNG_SEED <- 42


# --- Paths ---
CODE_DIR <- "R"
RESULTS_DIR <- "Results"

DATA_DIR <- "data"
DATA_FILE <- file.path(DATA_DIR, "emc2_design_matrix.csv")

MODELS_DIR <- "emc2_models"
LOG_FILE <- file.path(MODELS_DIR, "log.txt")


# --- Data Filtering ---
MIN_SACCADE_CUTOFF <- 0.23
MAX_SACCADE_CUTOFF <- 1.0
ALLOW_TARGET_REPEAT <- TRUE


# --- Fitting Params ---
NUM_CORES <- 8

# criteria for stopping the "sample" stage of model-fitting
MIN_NUM_SAMPLES <- 1000
MAX_TRIES <- 10   # number of times to check if "stop criteria" are met
STEP_SIZE <- 100  # number of iterations between "stop criteria" checks

# Asymmetric convergence thresholds applied to $mu and $alpha only.
# $sigma2 and $correlation are descriptive (not enforced) - see CLAUDE.md "Analysis workflow".
MAX_RHAT_MU    <- 1.05;  MIN_ESS_MU    <- 1000   # tighter: population params reported with CIs
MAX_RHAT_ALPHA <- 1.10;  MIN_ESS_ALPHA <- 500    # looser: subject params used for OOD simulation


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
