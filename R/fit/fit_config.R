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

# --- Intercept priors (log scale for B, A, t0) ---
# Only the parameters every model samples live here. Effect priors (slopes,
# interactions, sv terms) belong to the model script and are passed to
# build_lba_model() via extra_mu/extra_sd.
V_BASELINE_MU <- 2;           V_BASELINE_SD <- 2
B_BASELINE_MU <- log(1);      B_BASELINE_SD <- 1
A_MU          <- log(0.5);    A_SD          <- 1
T0_MU <- log(0.5 * MIN_SACCADE_CUTOFF);  T0_SD <- 1   # use saccade cutoff as initial t0 estimate


# ----------------------------------------------------------------------------
# Master prior table (intercepts only)
# ----------------------------------------------------------------------------
# Maps the intercept names to (mean, sd). build_lba_model() merges a model's
# `extra_mu`/`extra_sd` over these, selects the entries matching the design's
# `sampled_pars()` and errors on any sampled parameter with no entry, so a model
# must supply a prior for every effect it samples.
PRIOR_MU <- c(v = V_BASELINE_MU, B = B_BASELINE_MU, A = A_MU, t0 = T0_MU)
PRIOR_SD <- c(v = V_BASELINE_SD, B = B_BASELINE_SD, A = A_SD, t0 = T0_SD)

# Window (c(min, max) in seconds, inclusive) that simulated RTs are truncated
# to in the recovery and PPC simulations; NULL = untruncated. The likelihood is
# unaffected (observed RTs are filtered by MIN/MAX_SACCADE_CUTOFF).
SIM_RT_WINDOW <- NULL


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
