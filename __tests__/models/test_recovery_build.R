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
raw_fixture <- readr::read_csv(
  file.path(ROOT, "__tests__", "fixtures", "sample_data.csv"), show_col_types = FALSE
) %>%
  dplyr::mutate(
    search_difficulty    = factor(search_difficulty, levels=c("EASY","MIXED","DIFFICULT"), ordered=TRUE),
    cue_size             = factor(cue_size, levels=c("NONE","SMALL","MEDIUM","LARGE"), ordered=TRUE),
    R=factor(R), cue_location=factor(cue_location),
    target_location=factor(target_location), prev_target_location=factor(prev_target_location)
  ) %>%
  dplyr::mutate(dplyr::across(dplyr::where(is.character), factor),
                dplyr::across(dplyr::where(is.logical), factor))
fixture_data <- filter_data(raw_fixture,
                            min_rt               = MIN_SACCADE_CUTOFF,
                            max_rt               = MAX_SACCADE_CUTOFF,
                            allow_target_repeats = ALLOW_TARGET_REPEAT)

# ---------------------------------------------------------------------------
# Build the base emc object ONCE (design() + make_emc() is the expensive step)
# and derive the hand-crafted group_params used by every simulate test below.
# Rebuilding per test_that ballooned the suite; the only intentional second
# build is the rebuild-on-simulated-data check at the end.
# ---------------------------------------------------------------------------
emc_obj    <- build_model(fixture_data, n_chains = N_TEST_CHAINS)
design_obj <- extract_design(emc_obj)
sp         <- sampled_pars(design_obj)

# Hand-craft group_params using config priors as point estimates
# (same values as base_mu in build_model.R). Keep only params in this design.
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
group_means <- group_means[names(group_means) %in% sp]

# Identity-scaled covariance (0.1 * I) as a simple valid Sigma
Sigma <- diag(0.1, length(group_means))
rownames(Sigma) <- colnames(Sigma) <- names(group_means)

group_params <- list(mu = group_means, Sigma = Sigma)


# =============================================================================
# extract_design
# =============================================================================

test_that("extract_design: returns a list from a make_emc object", {
  expect_type(design_obj, "list")
})


# =============================================================================
# simulate_recovery_data with the hand-crafted group_params above
# (avoids needing a fitted posterior; tests make_random_effects + make_data path)
# =============================================================================

test_that("simulate_recovery_data: returns data frame and subject_pars matrix", {
  result <- simulate_recovery_data(emc_obj, group_params, fixture_data, seed = 101L)

  expect_type(result, "list")
  expect_setequal(names(result), c("data", "subject_pars"))
  expect_s3_class(result$data, "data.frame")
  expect_true(is.matrix(result$subject_pars))
})

test_that("simulate_recovery_data: simulated data has same columns as template", {
  result <- simulate_recovery_data(emc_obj, group_params, fixture_data, seed = 101L)

  # EMC2's make_data preserves the input data structure
  expect_true(all(c("rt", "R") %in% names(result$data)))
  expect_equal(nrow(result$data), nrow(fixture_data))
})

test_that("simulate_recovery_data: different seeds produce different RTs", {
  r1 <- simulate_recovery_data(emc_obj, group_params, fixture_data, seed = 101L)
  r2 <- simulate_recovery_data(emc_obj, group_params, fixture_data, seed = 102L)

  expect_false(identical(r1$data$rt, r2$data$rt))
})

test_that("build_model on simulated data produces emc object with N_TEST_CHAINS chains", {
  result       <- simulate_recovery_data(emc_obj, group_params, fixture_data, seed = 101L)
  recovery_emc <- build_model(result$data, n_chains = N_TEST_CHAINS)

  expect_type(recovery_emc, "list")
  expect_equal(length(recovery_emc), N_TEST_CHAINS)
})
