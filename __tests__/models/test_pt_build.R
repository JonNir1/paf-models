#' =============================================================================
#' Level-2 test: real EMC2 build of the full PrevTarget-locus model (pt_vAB)
#'
#' One build (design() is minutes) on the committed sample fixture restricted to
#' EASY/DIFFICULT trials, like the MODEL_DATA_ARGS of the pt scripts. Checks that
#' EMC2 samples exactly the 14 expected parameters and that the prior object
#' carries the PT_PRIOR_MU/SD values (an implicit check that every name in the
#' prior table matches EMC2's labels). No MCMC.
#' =============================================================================

library(testthat)
library(EMC2)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "fit", "helpers", "pt_family.R"))
source(file.path(ROOT, "__tests__", "models", "shared_assertions.R"))
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))
sys.source(file.path(ROOT, "R", "fit", "pt_vAB.R"), envir = (pt_vAB <- new.env(parent = globalenv())))

PT_VAB_PARAMS <- c(
  "v", "v_TargetAtLocTRUE", "v_SearchDifficultyDIFFICULT", "v_PrevTargetAtLocTRUE",
  "v_TargetAtLocTRUE:SearchDifficultyDIFFICULT", "v_TargetAtLocTRUE:PrevTargetAtLocTRUE",
  "v_SearchDifficultyDIFFICULT:PrevTargetAtLocTRUE",
  "v_TargetAtLocTRUE:SearchDifficultyDIFFICULT:PrevTargetAtLocTRUE",
  "sv_TargetAtLocTRUE", "B", "B_PrevTargetAtLocTRUE", "A", "A_PrevTargetAtLocTRUE", "t0")

pt_data <- local({
  d <- load_fixture_data()
  droplevels(d[d$search_difficulty != "MIXED", ])
})
pt_emc <- pt_vAB$build_model(pt_data, n_chains = 2L)


test_that("pt_vAB builds with exactly the 14 expected parameters (and pt_param_names agrees)", {
  expect_valid_emc(pt_emc, 2L)
  expect_setequal(names(emc_sampled_pars(.get_design(pt_emc))), PT_VAB_PARAMS)
  expect_setequal(pt_param_names(c("v", "A", "B")), PT_VAB_PARAMS)
})

test_that("pt_vAB prior means/SDs are the PT table for effects and fit_config for the intercepts", {
  prior <- pt_emc[[1]]$prior
  mu <- prior$theta_mu_mean
  sd <- sqrt(diag(prior$theta_mu_var))
  expect_equal(mu[names(PT_PRIOR_MU)], PT_PRIOR_MU * 1, ignore_attr = TRUE)
  expect_equal(unname(sd[names(PT_PRIOR_SD)]), unname(PT_PRIOR_SD * PT_PRIOR_SD_SCALE))
  expect_equal(unname(mu[c("v", "B", "A", "t0")]), unname(PRIOR_MU[c("v", "B", "A", "t0")]))
})
