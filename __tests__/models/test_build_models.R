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

raw  <- readr::read_csv(file.path(ROOT, "__tests__", "fixtures", "sample_data.csv"),
                        show_col_types = FALSE) %>%
  dplyr::mutate(
    search_difficulty    = factor(search_difficulty, levels=c("EASY","MIXED","DIFFICULT"), ordered=TRUE),
    cue_size             = factor(cue_size, levels=c("NONE","SMALL","MEDIUM","LARGE"), ordered=TRUE),
    R=factor(R), cue_location=factor(cue_location),
    target_location=factor(target_location), prev_target_location=factor(prev_target_location)
  ) %>%
  dplyr::mutate(dplyr::across(dplyr::where(is.character), factor),
                dplyr::across(dplyr::where(is.logical), factor))
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

# ---------------------------------------------------------------------------
# Build each model ONCE and reuse across all of that model's assertions.
# build_model() (design() + make_emc()) is the expensive step (~minutes per
# model, dominated by EMC2::design()); rebuilding inside every test_that
# ballooned the suite to hours. Each modelN.R redefines build_model(), so we
# source + build sequentially before sourcing the next.
# ---------------------------------------------------------------------------
source(file.path(ROOT, "R", "fit", "model1.R")); M1 <- build_model(data, n_chains = N_TEST_CHAINS)
source(file.path(ROOT, "R", "fit", "model2.R")); M2 <- build_model(data, n_chains = N_TEST_CHAINS)
source(file.path(ROOT, "R", "fit", "model3.R")); M3 <- build_model(data, n_chains = N_TEST_CHAINS)
source(file.path(ROOT, "R", "fit", "model4.R")); M4 <- build_model(data, n_chains = N_TEST_CHAINS)
source(file.path(ROOT, "R", "fit", "model5.R")); M5 <- build_model(data, n_chains = N_TEST_CHAINS)


# =============================================================================
# Model 1: v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc | B ~ SearchDifficulty
# =============================================================================

test_that("model1: valid emc object with correct n_chains", {
  expect_valid_emc(M1, N_TEST_CHAINS, "model1")
})

test_that("model1: v formula RHS", {
  expect_formula_rhs(M1, "v", "PrevTargetAtLoc + CueAtLoc + StimulusAtLoc", "model1")
})

test_that("model1: B formula RHS", {
  expect_formula_rhs(M1, "B", "SearchDifficulty", "model1")
})

test_that("model1: sv formula RHS is always StimulusAtLoc", {
  expect_formula_rhs(M1, "sv", "StimulusAtLoc", "model1")
})

test_that("model1: parameter names match expected set", {
  expected <- c(BASE_PARAMS,
                "B_SearchDifficultyMIXED", "B_SearchDifficultyDIFFICULT")
  expect_param_names(M1, expected, "model1")
})

test_that("model1: prior mean for v baseline matches config", {
  expect_prior_mean(M1, "v", V_BASELINE_MU, label = "model1")
})

test_that("model1: prior mean for B_SearchDifficultyMIXED matches config", {
  expect_prior_mean(M1, "B_SearchDifficultyMIXED", B_SEARCH_MIX_MU, label = "model1")
})


# =============================================================================
# Model 2: v ~ ... + SearchDifficulty | B ~ 1
# =============================================================================

test_that("model2: valid emc object with correct n_chains", {
  expect_valid_emc(M2, N_TEST_CHAINS, "model2")
})

test_that("model2: v formula RHS", {
  expect_formula_rhs(M2, "v",
    "PrevTargetAtLoc + CueAtLoc + StimulusAtLoc + SearchDifficulty", "model2")
})

test_that("model2: B formula RHS is 1", {
  expect_formula_rhs(M2, "B", "1", "model2")
})

test_that("model2: parameter names match expected set", {
  expected <- c(BASE_PARAMS,
                "v_SearchDifficultyMIXED", "v_SearchDifficultyDIFFICULT")
  expect_param_names(M2, expected, "model2")
})

test_that("model2: prior mean for v_SearchDifficultyMIXED matches config", {
  expect_prior_mean(M2, "v_SearchDifficultyMIXED", V_SEARCH_MIX_MU, label = "model2")
})


# =============================================================================
# Model 3: v ~ ... + StimulusAtLoc:SearchDifficulty | B ~ 1  [DEPRECATED]
# =============================================================================

test_that("model3: valid emc object with correct n_chains", {
  expect_valid_emc(M3, N_TEST_CHAINS, "model3")
})

test_that("model3: parameter names include 4 Stim:Diff interaction terms", {
  expected <- c(BASE_PARAMS,
                "v_StimulusAtLocD:SearchDifficultyMIXED",
                "v_StimulusAtLocD:SearchDifficultyDIFFICULT",
                "v_StimulusAtLocE:SearchDifficultyMIXED",
                "v_StimulusAtLocE:SearchDifficultyDIFFICULT")
  expect_param_names(M3, expected, "model3")
})

test_that("model3: prior mean for v baseline matches config", {
  expect_prior_mean(M3, "v", V_BASELINE_MU, label = "model3")
})


# =============================================================================
# Model 4: v ~ ... + StimulusAtLoc * SearchDifficulty | B ~ 1
# =============================================================================

test_that("model4: valid emc object with correct n_chains", {
  expect_valid_emc(M4, N_TEST_CHAINS, "model4")
})

test_that("model4: v formula RHS", {
  expect_formula_rhs(M4, "v",
    "PrevTargetAtLoc + CueAtLoc + StimulusAtLoc * SearchDifficulty", "model4")
})

test_that("model4: parameter names match expected set", {
  expected <- c(BASE_PARAMS,
                "v_SearchDifficultyMIXED", "v_SearchDifficultyDIFFICULT",
                "v_StimulusAtLocD:SearchDifficultyMIXED",
                "v_StimulusAtLocD:SearchDifficultyDIFFICULT",
                "v_StimulusAtLocE:SearchDifficultyMIXED",
                "v_StimulusAtLocE:SearchDifficultyDIFFICULT")
  expect_param_names(M4, expected, "model4")
})

test_that("model4: prior mean for v_StimulusAtLocD:SearchDifficultyMIXED matches config", {
  expect_prior_mean(M4, "v_StimulusAtLocD:SearchDifficultyMIXED",
                    V_STIM_D_SEARCH_MIX_MU, label = "model4")
})


# =============================================================================
# Model 5: v ~ ... + StimulusAtLoc * SearchDifficulty | B ~ SearchDifficulty
# =============================================================================

test_that("model5: valid emc object with correct n_chains", {
  expect_valid_emc(M5, N_TEST_CHAINS, "model5")
})

test_that("model5: B formula RHS is SearchDifficulty", {
  expect_formula_rhs(M5, "B", "SearchDifficulty", "model5")
})

test_that("model5: parameter names match expected set (model4 + B_SearchDiff params)", {
  expected <- c(BASE_PARAMS,
                "v_SearchDifficultyMIXED", "v_SearchDifficultyDIFFICULT",
                "v_StimulusAtLocD:SearchDifficultyMIXED",
                "v_StimulusAtLocD:SearchDifficultyDIFFICULT",
                "v_StimulusAtLocE:SearchDifficultyMIXED",
                "v_StimulusAtLocE:SearchDifficultyDIFFICULT",
                "B_SearchDifficultyMIXED", "B_SearchDifficultyDIFFICULT")
  expect_param_names(M5, expected, "model5")
})

test_that("model5: prior mean for B_SearchDifficultyDIFFICULT matches config", {
  expect_prior_mean(M5, "B_SearchDifficultyDIFFICULT", B_SEARCH_DIF_MU, label = "model5")
})
