#' =============================================================================
#' Synthetic test model for the test suite (L2 build + L3 fit smoke).
#'
#' A minimal LBA variant built via build_lba_model() with cheap formulas: an
#' additive v-formula (PrevTargetAtLoc + CueAtLoc + StimulusAtLoc), sv ~
#' StimulusAtLoc and B ~ 1 (no SearchDifficulty term). Its effect priors are
#' declared here (TEST_MODEL_PRIOR_MU/SD) and passed via extra_mu/extra_sd; their
#' values match the committed fitted fixtures, so do not change them. This keeps
#' EMC2::design() as fast as possible while still exercising the whole build ->
#' make_emc -> fit pipeline independently of any real model family. The retired
#' model1-5 definitions live on the `analysis1` branch.
#'
#' Defines both `build_model()` (the contract name expected by fit_cloud.R and
#' run_recovery_fit) and a `build_test_model()` alias for readability in tests,
#' plus MODEL_NAME and STRUCTURAL_UNIDENTIFIABLE_PATTERN.
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/build_model.R")

MODEL_NAME <- "test_model"

# NA: additive v formula and B ~ 1 (no SearchDifficulty term), so the partially
# nested StimulusAtLoc x SearchDifficulty block does not exist; all parameters are identifiable.
STRUCTURAL_UNIDENTIFIABLE_PATTERN <- NA_character_

# Effect priors of the fixture model (the committed fitted fixtures were made with these).
TEST_MODEL_PRIOR_MU <- c(
  v_PrevTargetAtLocTRUE = 0.75,
  v_CueAtLocSMALL       = 0.1,
  v_CueAtLocMEDIUM      = 0.5,
  v_CueAtLocLARGE       = 1,
  v_StimulusAtLocD      = -0.5,
  v_StimulusAtLocE      = -1.5,
  sv_StimulusAtLocD     = log(1),
  sv_StimulusAtLocE     = log(1)
)
TEST_MODEL_PRIOR_SD <- setNames(rep(1, length(TEST_MODEL_PRIOR_MU)), names(TEST_MODEL_PRIOR_MU))

build_model <- function(data, n_chains = 2) {
  build_lba_model(
    data       = data,
    n_chains   = n_chains,
    v_formula  = v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc,
    sv_formula = sv ~ StimulusAtLoc,
    B_formula  = B ~ 1,
    extra_mu   = TEST_MODEL_PRIOR_MU,
    extra_sd   = TEST_MODEL_PRIOR_SD
  )
}

build_test_model <- build_model


#' Known-good, in-bounds group parameters for exercising the recovery chain
#' WITHOUT a real fitted posterior (L2 build + L3 smoke).
#'
#' Uses the model's prior means (config PRIOR_MU + TEST_MODEL_PRIOR_MU) as point estimates
#' (the values the model is built with, so simulated alpha land in bounds) plus a tame diagonal Sigma. Extracting
#' (mu, Sigma) from a tiny under-converged smoke fit instead yields unreliable
#' means and a diffuse Sigma, so make_data() rejects >10% of draws as
#' out-of-bounds. Production recovery extracts from a converged fit and is fine.
#'
#' @param design A design object (from extract_design()).
#' @param sd     Per-parameter prior SD for the diagonal Sigma (default 0.1).
#' @return list(mu = named numeric, Sigma = named square matrix), filtered to
#'   exactly the design's sampled parameters.
test_group_params <- function(design, sd = 0.1) {
  # sampled_pars() returns a NAMED numeric vector -> filter on names, not values.
  sp       <- emc_sampled_pars(design)
  sp_names <- if (!is.null(names(sp))) names(sp) else as.character(sp)
  all_mu   <- c(PRIOR_MU, TEST_MODEL_PRIOR_MU)
  missing  <- setdiff(sp_names, names(all_mu))
  if (length(missing) > 0L)
    stop(sprintf("No PRIOR_MU entry for sampled parameter(s): %s", paste(missing, collapse = ", ")))
  mu <- all_mu[sp_names]

  Sigma <- diag(sd, length(mu))
  dimnames(Sigma) <- list(names(mu), names(mu))
  list(mu = mu, Sigma = Sigma)
}
