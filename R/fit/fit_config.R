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


# ----------------------------------------------------------------------------
# Master prior table
# ----------------------------------------------------------------------------
# Single source of truth mapping every POSSIBLE sampled parameter name to its
# (mean, sd). build_lba_model() selects the entries matching the design's
# `sampled_pars()` and errors on any sampled parameter with no entry here, so a
# model family simply adds its parameter names below. Per-model `extra_mu`/
# `extra_sd` override or extend these. Derived from the scalar constants above
# (which remain the editable values and are referenced directly by tests).
PRIOR_MU <- c(
  v                     = V_BASELINE_MU,
  v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_MU,
  v_CueAtLocSMALL       = V_CUE_S_MU,
  v_CueAtLocMEDIUM      = V_CUE_M_MU,
  v_CueAtLocLARGE       = V_CUE_L_MU,
  v_StimulusAtLocD      = V_STIM_D_MU,
  v_StimulusAtLocE      = V_STIM_E_MU,
  sv_StimulusAtLocD     = SV_STIM_D_MU,
  sv_StimulusAtLocE     = SV_STIM_E_MU,
  B                     = B_BASELINE_MU,
  A                     = A_MU,
  t0                    = T0_MU
)
PRIOR_SD <- c(
  v                     = V_BASELINE_SD,
  v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_SD,
  v_CueAtLocSMALL       = V_CUE_S_SD,
  v_CueAtLocMEDIUM      = V_CUE_M_SD,
  v_CueAtLocLARGE       = V_CUE_L_SD,
  v_StimulusAtLocD      = V_STIM_D_SD,
  v_StimulusAtLocE      = V_STIM_E_SD,
  sv_StimulusAtLocD     = SV_STIM_D_SD,
  sv_StimulusAtLocE     = SV_STIM_E_SD,
  B                     = B_BASELINE_SD,
  A                     = A_SD,
  t0                    = T0_SD
)


# ============================================================================
# Model Fitting
# Defaults for the unified fit_to_convergence() loop (helpers/fitting.R).
# ============================================================================

# --- MCMC chains ---
# Number of MCMC chains baked into each emc object at make_emc() time.
# Cannot be changed after fitting. Parallelism (cores_for_chains, cores_per_chain)
# is auto-detected at runtime by get_core_args() in helpers/fitting.R.
N_CHAINS <- 3

# --- Fit loop defaults ---
# fit_to_convergence() warms up a fresh model then adds `STEP_SIZE` sampling
# iterations per try, up to `MAX_TRIES` tries, until the convergence_criteria are
# met. `STEP_SIZE` is the `batch_size` argument; `SAVE_EVERY` the checkpoint cadence.
MAX_TRIES  <- 20    # max number of sampling batches to add
STEP_SIZE  <- 200   # sample iters added per try (batch_size)
SAVE_EVERY <- 2L    # default checkpoint cadence (every N tries); NULL disables

# Sample-stage floor for production fits: keep sampling until total sample-stage
# iterations per chain reach this, even after Rhat/ESS criteria are met.
EXTENDED_FIT_SAMPLES <- 3000L


# --- Convergence thresholds (asymmetric; mu tighter than alpha) ---
# Defined in R/config.R (sourced above) so the evaluation layer can reuse them
# as a single source of truth: MAX_RHAT_MU, MIN_ESS_MU, MAX_RHAT_ALPHA, MIN_ESS_ALPHA.
#
#' Build a convergence_criteria list for fit_to_convergence().
#' Gates $mu and $alpha on the asymmetric thresholds; $sigma2 and $correlation
#' are omitted (descriptive-only, per the within-subject design).
#' @param profile "standard" (production) or "recovery" (relaxed, diagnostic).
#' @return A convergence_criteria list: num_samples + per-group max_rhat/min_ess.
default_convergence_criteria <- function(profile = c("standard", "recovery")) {
  profile <- match.arg(profile)
  if (profile == "recovery") {
    list(num_samples = RECOVERY_FIT_SAMPLES,
         mu    = list(max_rhat = MAX_RHAT_MU_RECOVERY,    min_ess = MIN_ESS_MU_RECOVERY),
         alpha = list(max_rhat = MAX_RHAT_ALPHA_RECOVERY, min_ess = MIN_ESS_ALPHA_RECOVERY))
  } else {
    list(num_samples = EXTENDED_FIT_SAMPLES,
         mu    = list(max_rhat = MAX_RHAT_MU,    min_ess = MIN_ESS_MU),
         alpha = list(max_rhat = MAX_RHAT_ALPHA, min_ess = MIN_ESS_ALPHA))
  }
}

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
