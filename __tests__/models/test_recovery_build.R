#' =============================================================================
#' Level-2 test: full recovery pipeline on fixture data (requires EMC2)
#'
#' Tests the extract -> simulate -> build_model chain using the committed
#' sample_data.csv fixture. Does NOT run MCMC (only verifies that the emc
#' object is built correctly from simulated data).
#' =============================================================================

.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)
library(EMC2)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "fit", "helpers", "recovery.R"))
source(file.path(ROOT, "R", "fit", "model1.R"))   # defines build_model()

N_TEST_CHAINS <- 2L

# Load fixture data (same as used by test_build_models.R)
raw_fixture <- load_safe_csv(file.path(ROOT, "__tests__", "fixtures", "sample_data.csv"))
fixture_data <- filter_data(raw_fixture,
                            min_rt               = MIN_SACCADE_CUTOFF,
                            max_rt               = MAX_SACCADE_CUTOFF,
                            allow_target_repeats = ALLOW_TARGET_REPEAT)


# =============================================================================
# Build a minimal fitted model on fixture data to test extract_* functions.
# We use make_emc only (no MCMC sampling) -- returns a valid emc object whose
# structure contains the design closure needed by extract_design().
# =============================================================================

test_that("extract_design: returns a list from a make_emc object", {
  emc_obj <- build_model(fixture_data, n_chains = N_TEST_CHAINS)
  design  <- extract_design(emc_obj)
  expect_type(design, "list")
})


# =============================================================================
# simulate_recovery_data with hand-crafted group_params
# (avoids needing a fitted posterior; tests make_random_effects + make_data path)
# =============================================================================

test_that("simulate_recovery_data: returns data frame and subject_pars matrix", {
  emc_obj <- build_model(fixture_data, n_chains = N_TEST_CHAINS)

  # Hand-craft group_params using config priors as point estimates
  design_obj <- extract_design(emc_obj)
  sp <- sampled_pars(design_obj)
  n_pars <- length(sp)

  # Use prior means as group_means (same values as base_mu in build_model.R)
  group_means <- c(
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
    B_SearchDifficultyMIXED     = B_SEARCH_MIX_MU,
    B_SearchDifficultyDIFFICULT = B_SEARCH_DIF_MU,
    A                     = A_MU,
    t0                    = T0_MU
  )
  # Keep only parameters that appear in this model's design
  group_means <- group_means[names(group_means) %in% sp]

  # Use identity-scaled covariance (0.1 * I) as a simple valid Sigma
  n_g   <- length(group_means)
  Sigma <- diag(0.1, n_g)
  rownames(Sigma) <- colnames(Sigma) <- names(group_means)

  group_params <- list(mu = group_means, Sigma = Sigma)

  result <- simulate_recovery_data(emc_obj, group_params, fixture_data, seed = 101L)

  # Structure checks
  expect_type(result, "list")
  expect_setequal(names(result), c("data", "subject_pars"))
  expect_s3_class(result$data, "data.frame")
  expect_true(is.matrix(result$subject_pars))
})

test_that("simulate_recovery_data: simulated data has same columns as template", {
  emc_obj    <- build_model(fixture_data, n_chains = N_TEST_CHAINS)
  design_obj <- extract_design(emc_obj)
  sp         <- sampled_pars(design_obj)

  group_means <- c(
    v = V_BASELINE_MU, v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_MU,
    v_CueAtLocSMALL = V_CUE_S_MU, v_CueAtLocMEDIUM = V_CUE_M_MU,
    v_CueAtLocLARGE = V_CUE_L_MU, v_StimulusAtLocD = V_STIM_D_MU,
    v_StimulusAtLocE = V_STIM_E_MU, sv_StimulusAtLocD = SV_STIM_D_MU,
    sv_StimulusAtLocE = SV_STIM_E_MU, B = B_BASELINE_MU,
    B_SearchDifficultyMIXED = B_SEARCH_MIX_MU,
    B_SearchDifficultyDIFFICULT = B_SEARCH_DIF_MU,
    A = A_MU, t0 = T0_MU
  )
  group_means <- group_means[names(group_means) %in% sp]
  n_g   <- length(group_means)
  Sigma <- diag(0.1, n_g)
  rownames(Sigma) <- colnames(Sigma) <- names(group_means)

  result <- simulate_recovery_data(
    emc_obj, list(mu = group_means, Sigma = Sigma), fixture_data, seed = 101L
  )

  # EMC2's make_data preserves the input data structure
  expect_true(all(c("rt", "R") %in% names(result$data)))
  expect_equal(nrow(result$data), nrow(fixture_data))
})

test_that("simulate_recovery_data: different seeds produce different RTs", {
  emc_obj    <- build_model(fixture_data, n_chains = N_TEST_CHAINS)
  design_obj <- extract_design(emc_obj)
  sp         <- sampled_pars(design_obj)

  group_means <- c(
    v = V_BASELINE_MU, v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_MU,
    v_CueAtLocSMALL = V_CUE_S_MU, v_CueAtLocMEDIUM = V_CUE_M_MU,
    v_CueAtLocLARGE = V_CUE_L_MU, v_StimulusAtLocD = V_STIM_D_MU,
    v_StimulusAtLocE = V_STIM_E_MU, sv_StimulusAtLocD = SV_STIM_D_MU,
    sv_StimulusAtLocE = SV_STIM_E_MU, B = B_BASELINE_MU,
    B_SearchDifficultyMIXED = B_SEARCH_MIX_MU,
    B_SearchDifficultyDIFFICULT = B_SEARCH_DIF_MU,
    A = A_MU, t0 = T0_MU
  )
  group_means <- group_means[names(group_means) %in% sp]
  n_g   <- length(group_means)
  Sigma <- diag(0.1, n_g)
  rownames(Sigma) <- colnames(Sigma) <- names(group_means)
  gp <- list(mu = group_means, Sigma = Sigma)

  r1 <- simulate_recovery_data(emc_obj, gp, fixture_data, seed = 101L)
  r2 <- simulate_recovery_data(emc_obj, gp, fixture_data, seed = 102L)

  expect_false(identical(r1$data$rt, r2$data$rt))
})

test_that("build_model on simulated data produces emc object with N_TEST_CHAINS chains", {
  emc_obj    <- build_model(fixture_data, n_chains = N_TEST_CHAINS)
  design_obj <- extract_design(emc_obj)
  sp         <- sampled_pars(design_obj)

  group_means <- c(
    v = V_BASELINE_MU, v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_MU,
    v_CueAtLocSMALL = V_CUE_S_MU, v_CueAtLocMEDIUM = V_CUE_M_MU,
    v_CueAtLocLARGE = V_CUE_L_MU, v_StimulusAtLocD = V_STIM_D_MU,
    v_StimulusAtLocE = V_STIM_E_MU, sv_StimulusAtLocD = SV_STIM_D_MU,
    sv_StimulusAtLocE = SV_STIM_E_MU, B = B_BASELINE_MU,
    B_SearchDifficultyMIXED = B_SEARCH_MIX_MU,
    B_SearchDifficultyDIFFICULT = B_SEARCH_DIF_MU,
    A = A_MU, t0 = T0_MU
  )
  group_means <- group_means[names(group_means) %in% sp]
  n_g   <- length(group_means)
  Sigma <- diag(0.1, n_g)
  rownames(Sigma) <- colnames(Sigma) <- names(group_means)

  result   <- simulate_recovery_data(emc_obj, list(mu = group_means, Sigma = Sigma),
                                     fixture_data, seed = 101L)
  recovery_emc <- build_model(result$data, n_chains = N_TEST_CHAINS)

  expect_type(recovery_emc, "list")
  expect_equal(length(recovery_emc), N_TEST_CHAINS)
})
