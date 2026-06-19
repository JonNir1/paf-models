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
#' plus MODEL_NAME.
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/build_model.R")

MODEL_NAME <- "test_model"

build_model <- function(data, n_chains = 2) {
  build_lba_model(
    data      = data,
    n_chains  = n_chains,
    v_formula = v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc,
    B_formula = B ~ 1
  )
}

build_test_model <- build_model
