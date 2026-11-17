#' =============================================================================
#' Synthetic test model for the test suite (L2 build + L3 fit smoke).
#'
#' A minimal LBA variant built via build_lba_model() with the simplest formulas
#' that are compatible with the shared base priors: the full base v-formula
#' (PrevTargetAtLoc + CueAtLoc + StimulusAtLoc, matching the base prior names)
#' and the cheapest B ~ 1 threshold (no SearchDifficulty term, no model-specific
#' extras). This keeps EMC2::design() as fast as possible while still exercising
#' the whole build -> make_emc -> fit pipeline independently of any real model
#' family. The retired model1-5 definitions live on the `analysis1` branch.
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

build_model <- function(data, n_chains = 2) {
  build_lba_model(
    data      = data,
    n_chains  = n_chains,
    v_formula = v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc,
    B_formula = B ~ 1
  )
}

build_test_model <- build_model


#' Known-good, in-bounds group parameters for exercising the recovery chain
#' WITHOUT a real fitted posterior (L2 build + L3 smoke).
#'
#' Uses the config prior means (PRIOR_MU) as point estimates (the values the model is built
#' with, so simulated alpha land in bounds) plus a tame diagonal Sigma. Extracting
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
  missing  <- setdiff(sp_names, names(PRIOR_MU))
  if (length(missing) > 0L)
    stop(sprintf("No PRIOR_MU entry for sampled parameter(s): %s", paste(missing, collapse = ", ")))
  mu <- PRIOR_MU[names(PRIOR_MU) %in% sp_names]   # PRIOR_MU order

  Sigma <- diag(sd, length(mu))
  dimnames(Sigma) <- list(names(mu), names(mu))
  list(mu = mu, Sigma = Sigma)
}
