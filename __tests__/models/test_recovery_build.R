#' =============================================================================
#' Level-2 test: model build + full recovery pipeline on fixture data (EMC2)
#'
#' Builds the synthetic test model ONCE (design() + make_emc() is the expensive
#' step) and reuses it to guard BOTH:
#'   (a) build_lba_model() / make_emc() structure + formulas + base priors, and
#'   (b) the extract -> simulate -> build_model recovery chain.
#' Uses the committed sample_data.csv fixture; does NOT run MCMC.
#' =============================================================================

.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)
library(EMC2)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "fit", "helpers", "recovery.R"))
source(file.path(ROOT, "__tests__", "models", "shared_assertions.R"))  # expect_valid_emc, etc.
source(file.path(ROOT, "__tests__", "fixtures", "test_model.R"))   # defines build_model()

N_TEST_CHAINS <- 2L

# Load the committed fixture (one row per trial, 15 columns)
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


# =============================================================================
# (a) Build structure: valid emc object, expected formulas, base prior means
# =============================================================================

test_that("build_model: returns a valid emc object with N_TEST_CHAINS chains", {
  expect_valid_emc(emc_obj, N_TEST_CHAINS)
})

test_that("build_model: v / B / sv formulas match the synthetic spec", {
  expect_formula_rhs(emc_obj, "v",  "PrevTargetAtLoc + CueAtLoc + StimulusAtLoc")
  expect_formula_rhs(emc_obj, "B",  "1")
  expect_formula_rhs(emc_obj, "sv", "StimulusAtLoc")
})

test_that("build_model: base prior means come from fit_config.R", {
  expect_prior_mean(emc_obj, "v",  V_BASELINE_MU)
  expect_prior_mean(emc_obj, "t0", T0_MU)
})

# Known-good, in-bounds group params (config means + tame diagonal Sigma), built
# by the shared fixture helper so L2 and the L3 recovery smoke stay in sync.
group_params <- test_group_params(design_obj)


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
