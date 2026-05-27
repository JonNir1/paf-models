.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)
library(EMC2)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/helpers/build_model.R")     # transitively brings config + fit_config
source(file.path(ROOT, "__tests__", "models", "shared_assertions.R"))

# Load and filter fixture data once for all model tests.
# n_chains = 2 (faster than 3; sufficient to verify structure).
N_TEST_CHAINS <- 2L

raw  <- load_safe_csv(file.path(ROOT, "__tests__", "fixtures", "sample_data.csv"))
data <- filter_data(raw, min_rt = MIN_SACCADE_CUTOFF, max_rt = MAX_SACCADE_CUTOFF,
                    allow_target_repeats = ALLOW_TARGET_REPEAT)

# Base parameter set shared by all 5 models
BASE_PARAMS <- c(
  "v", "v_PrevTargetAtLocTRUE",
  "v_CueAtLocSMALL", "v_CueAtLocMEDIUM", "v_CueAtLocLARGE",
  "v_StimulusAtLocD", "v_StimulusAtLocE",
  "sv_StimulusAtLocD", "sv_StimulusAtLocE",
  "B", "A", "t0"
)


# =============================================================================
# Model 1: v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc | B ~ SearchDifficulty
# =============================================================================

test_that("model1: valid emc object with correct n_chains", {
  source(file.path(ROOT, "R", "fit", "model1.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_valid_emc(m, N_TEST_CHAINS, "model1")
})

test_that("model1: v formula RHS", {
  source(file.path(ROOT, "R", "fit", "model1.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_formula_rhs(m, "v", "PrevTargetAtLoc + CueAtLoc + StimulusAtLoc", "model1")
})

test_that("model1: B formula RHS", {
  source(file.path(ROOT, "R", "fit", "model1.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_formula_rhs(m, "B", "SearchDifficulty", "model1")
})

test_that("model1: sv formula RHS is always StimulusAtLoc", {
  source(file.path(ROOT, "R", "fit", "model1.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_formula_rhs(m, "sv", "StimulusAtLoc", "model1")
})

test_that("model1: parameter names match expected set", {
  source(file.path(ROOT, "R", "fit", "model1.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expected <- c(BASE_PARAMS,
                "B_SearchDifficultyMIXED", "B_SearchDifficultyDIFFICULT")
  expect_param_names(m, expected, "model1")
})

test_that("model1: prior mean for v baseline matches config", {
  source(file.path(ROOT, "R", "fit", "model1.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_prior_mean(m, "v", V_BASELINE_MU, label = "model1")
})

test_that("model1: prior mean for B_SearchDifficultyMIXED matches config", {
  source(file.path(ROOT, "R", "fit", "model1.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_prior_mean(m, "B_SearchDifficultyMIXED", B_SEARCH_MIX_MU, label = "model1")
})


# =============================================================================
# Model 2: v ~ ... + SearchDifficulty | B ~ 1
# =============================================================================

test_that("model2: valid emc object with correct n_chains", {
  source(file.path(ROOT, "R", "fit", "model2.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_valid_emc(m, N_TEST_CHAINS, "model2")
})

test_that("model2: v formula RHS", {
  source(file.path(ROOT, "R", "fit", "model2.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_formula_rhs(m, "v",
    "PrevTargetAtLoc + CueAtLoc + StimulusAtLoc + SearchDifficulty", "model2")
})

test_that("model2: B formula RHS is 1", {
  source(file.path(ROOT, "R", "fit", "model2.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_formula_rhs(m, "B", "1", "model2")
})

test_that("model2: parameter names match expected set", {
  source(file.path(ROOT, "R", "fit", "model2.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expected <- c(BASE_PARAMS,
                "v_SearchDifficultyMIXED", "v_SearchDifficultyDIFFICULT")
  expect_param_names(m, expected, "model2")
})

test_that("model2: prior mean for v_SearchDifficultyMIXED matches config", {
  source(file.path(ROOT, "R", "fit", "model2.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_prior_mean(m, "v_SearchDifficultyMIXED", V_SEARCH_MIX_MU, label = "model2")
})


# =============================================================================
# Model 3: v ~ ... + StimulusAtLoc:SearchDifficulty | B ~ 1  [DEPRECATED]
# =============================================================================

test_that("model3: valid emc object with correct n_chains", {
  source(file.path(ROOT, "R", "fit", "model3.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_valid_emc(m, N_TEST_CHAINS, "model3")
})

test_that("model3: parameter names include 4 Stim:Diff interaction terms", {
  source(file.path(ROOT, "R", "fit", "model3.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expected <- c(BASE_PARAMS,
                "v_StimulusAtLocD:SearchDifficultyMIXED",
                "v_StimulusAtLocD:SearchDifficultyDIFFICULT",
                "v_StimulusAtLocE:SearchDifficultyMIXED",
                "v_StimulusAtLocE:SearchDifficultyDIFFICULT")
  expect_param_names(m, expected, "model3")
})

test_that("model3: prior mean for v baseline matches config", {
  source(file.path(ROOT, "R", "fit", "model3.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_prior_mean(m, "v", V_BASELINE_MU, label = "model3")
})


# =============================================================================
# Model 4: v ~ ... + StimulusAtLoc * SearchDifficulty | B ~ 1
# =============================================================================

test_that("model4: valid emc object with correct n_chains", {
  source(file.path(ROOT, "R", "fit", "model4.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_valid_emc(m, N_TEST_CHAINS, "model4")
})

test_that("model4: v formula RHS", {
  source(file.path(ROOT, "R", "fit", "model4.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_formula_rhs(m, "v",
    "PrevTargetAtLoc + CueAtLoc + StimulusAtLoc * SearchDifficulty", "model4")
})

test_that("model4: parameter names match expected set", {
  source(file.path(ROOT, "R", "fit", "model4.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expected <- c(BASE_PARAMS,
                "v_SearchDifficultyMIXED", "v_SearchDifficultyDIFFICULT",
                "v_StimulusAtLocD:SearchDifficultyMIXED",
                "v_StimulusAtLocD:SearchDifficultyDIFFICULT",
                "v_StimulusAtLocE:SearchDifficultyMIXED",
                "v_StimulusAtLocE:SearchDifficultyDIFFICULT")
  expect_param_names(m, expected, "model4")
})

test_that("model4: prior mean for v_StimulusAtLocD:SearchDifficultyMIXED matches config", {
  source(file.path(ROOT, "R", "fit", "model4.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_prior_mean(m, "v_StimulusAtLocD:SearchDifficultyMIXED",
                    V_STIM_D_SEARCH_MIX_MU, label = "model4")
})


# =============================================================================
# Model 5: v ~ ... + StimulusAtLoc * SearchDifficulty | B ~ SearchDifficulty
# =============================================================================

test_that("model5: valid emc object with correct n_chains", {
  source(file.path(ROOT, "R", "fit", "model5.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_valid_emc(m, N_TEST_CHAINS, "model5")
})

test_that("model5: B formula RHS is SearchDifficulty", {
  source(file.path(ROOT, "R", "fit", "model5.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_formula_rhs(m, "B", "SearchDifficulty", "model5")
})

test_that("model5: parameter names match expected set (model4 + B_SearchDiff params)", {
  source(file.path(ROOT, "R", "fit", "model5.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expected <- c(BASE_PARAMS,
                "v_SearchDifficultyMIXED", "v_SearchDifficultyDIFFICULT",
                "v_StimulusAtLocD:SearchDifficultyMIXED",
                "v_StimulusAtLocD:SearchDifficultyDIFFICULT",
                "v_StimulusAtLocE:SearchDifficultyMIXED",
                "v_StimulusAtLocE:SearchDifficultyDIFFICULT",
                "B_SearchDifficultyMIXED", "B_SearchDifficultyDIFFICULT")
  expect_param_names(m, expected, "model5")
})

test_that("model5: prior mean for B_SearchDifficultyDIFFICULT matches config", {
  source(file.path(ROOT, "R", "fit", "model5.R"))
  m <- build_model(data, n_chains = N_TEST_CHAINS)
  expect_prior_mean(m, "B_SearchDifficultyDIFFICULT", B_SEARCH_DIF_MU, label = "model5")
})
