#' =============================================================================
#' Level-2 test: model build + recovery simulation on fixture data (EMC2)
#'
#' Builds the synthetic test model ONCE (design() + make_emc() is the expensive
#' step, ~minutes) and reuses it to guard BOTH:
#'   (a) build_lba_model() / make_emc() structure + formulas + base priors, and
#'   (b) the extract -> simulate step of the recovery chain, plus a structural
#'       check that the simulated data can feed build_model() again.
#' The actual rebuild on simulated data (a second design()) runs in the L3
#' recovery smoke (smoke C). The control flow is unit-tested at L1.
#' Uses the committed sample_data.csv fixture; does NOT run MCMC.
#' =============================================================================

library(testthat)
library(EMC2)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "fit", "helpers", "recovery.R"))
source(file.path(ROOT, "__tests__", "models", "shared_assertions.R"))  # expect_valid_emc, etc.
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))           # load_fixture_data()
source(file.path(ROOT, "__tests__", "fixtures", "test_model.R"))       # defines build_model()

N_TEST_CHAINS <- 2L

fixture_data <- load_fixture_data()
emc_obj      <- build_model(fixture_data, n_chains = N_TEST_CHAINS)
design_obj   <- extract_design(emc_obj)
group_params <- test_group_params(design_obj)   # in-bounds config means + tame Sigma


test_that("build_model: valid emc object with the synthetic formulas and config prior means", {
  expect_valid_emc(emc_obj, N_TEST_CHAINS)
  expect_formula_rhs(emc_obj, "v",  "PrevTargetAtLoc + CueAtLoc + StimulusAtLoc")
  expect_formula_rhs(emc_obj, "B",  "1")
  expect_formula_rhs(emc_obj, "sv", "StimulusAtLoc")
  expect_prior_mean(emc_obj, "v",  V_BASELINE_MU)
  expect_prior_mean(emc_obj, "t0", T0_MU)
})

sim1 <- simulate_recovery_data(emc_obj, group_params, fixture_data, seed = 101L)
sim2 <- simulate_recovery_data(emc_obj, group_params, fixture_data, seed = 102L)

test_that("simulate_recovery_data: per-subject params and a template-shaped data set, seed-dependent", {
  expect_setequal(names(sim1), c("data", "subject_pars"))
  expect_true(is.matrix(sim1$subject_pars))
  expect_equal(nrow(sim1$subject_pars), length(unique(fixture_data$subjects)))
  expect_setequal(colnames(sim1$subject_pars), names(group_params$mu))

  expect_s3_class(sim1$data, "data.frame")
  expect_equal(nrow(sim1$data), nrow(fixture_data))
  expect_true(all(is.finite(sim1$data$rt) & sim1$data$rt > 0))
  expect_false(identical(sim1$data$rt, sim2$data$rt))
})

# What build_model() consumes from the data is every non-response column plus
# the factor levels; if those match the template, the rebuild sees the same
# design grid as the original build.
test_that("simulate_recovery_data: keeps every design input column and factor level of the template", {
  expect_true(all(names(fixture_data) %in% names(sim1$data)))
  design_cols <- setdiff(names(fixture_data), c("rt", "R"))
  for (col in design_cols) {
    expect_equal(as.character(sim1$data[[col]]), as.character(fixture_data[[col]]), label = col)
    if (is.factor(fixture_data[[col]])) {
      expect_identical(levels(sim1$data[[col]]), levels(fixture_data[[col]]), label = col)
    }
  }
  expect_identical(levels(sim1$data$R), levels(fixture_data$R))
})
