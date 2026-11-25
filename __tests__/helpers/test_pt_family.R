#' =============================================================================
#' Level-1 tests (no EMC2) for the analysis2 PrevTarget-locus family
#' (R/fit/helpers/pt_family.R + the eight R/fit/pt_*.R scripts) and the
#' prior-predictive helpers.
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/helpers/data.R")
source_root("R/fit/helpers/pt_family.R")
source_root("R/eval/helpers/prior_predictive.R")
source_root("R/eval/eval_config.R")   # MODEL_EXCLUDE_PATTERN, discover_model_names, check_model_names
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))

PT_SCRIPTS <- list.files(file.path(ROOT, "R", "fit"), pattern = "^pt_.*[.]R$", full.names = TRUE)

# Sampled parameters per model, written out by hand (not derived from the code under test):
# 8 base parameters, +4 v effects with PrevTargetAtLoc on v, +1 each on B and A.
PT_BASE <- c("v", "v_TargetAtLocTRUE", "v_SearchDifficultyDIFFICULT",
             "v_TargetAtLocTRUE:SearchDifficultyDIFFICULT", "sv_TargetAtLocTRUE", "B", "A", "t0")
PT_ON_V <- c("v_PrevTargetAtLocTRUE", "v_TargetAtLocTRUE:PrevTargetAtLocTRUE",
             "v_SearchDifficultyDIFFICULT:PrevTargetAtLocTRUE",
             "v_TargetAtLocTRUE:SearchDifficultyDIFFICULT:PrevTargetAtLocTRUE")
PT_ON_B <- "B_PrevTargetAtLocTRUE"
PT_ON_A <- "A_PrevTargetAtLocTRUE"
PT_EXPECTED <- list(
  pt_null = PT_BASE,
  pt_v    = c(PT_BASE, PT_ON_V),
  pt_A    = c(PT_BASE, PT_ON_A),
  pt_B    = c(PT_BASE, PT_ON_B),
  pt_vA   = c(PT_BASE, PT_ON_V, PT_ON_A),
  pt_vB   = c(PT_BASE, PT_ON_V, PT_ON_B),
  pt_AB   = c(PT_BASE, PT_ON_A, PT_ON_B),
  pt_vAB  = c(PT_BASE, PT_ON_V, PT_ON_A, PT_ON_B)
)
PT_N_PARAMS <- c(pt_null = 8L, pt_v = 12L, pt_A = 9L, pt_B = 9L, pt_vA = 13L, pt_vB = 13L, pt_AB = 10L, pt_vAB = 14L)

# What each script's build_model() hands to build_lba_model() (captured, no EMC2).
captured_build <- function(script) {
  env <- new.env(parent = globalenv())
  sys.source(script, envir = env)
  got <- NULL
  local_mocks(build_lba_model = function(...) { got <<- list(...); "built" }, .frame = parent.frame())
  env$build_model(data = NULL, n_chains = 2)
  got
}


test_that("pt family: eight scripts with unique MODEL_NAMEs equal to their file stems", {
  expect_length(PT_SCRIPTS, 8L)
  names_declared <- vapply(PT_SCRIPTS, model_script_name, character(1))
  expect_identical(unname(names_declared), tools::file_path_sans_ext(basename(PT_SCRIPTS)))
  expect_false(anyDuplicated(tolower(names_declared)) > 0)   # Windows file names are case-insensitive
})

# Reason: a sampled parameter without a prior only fails after minutes of design(); this catches it in ms.
test_that("pt family: per-model parameter table, and every sampled parameter has a prior (no unused prior)", {
  expect_identical(vapply(PT_EXPECTED, length, integer(1)), PT_N_PARAMS)
  for (script in PT_SCRIPTS) {
    model   <- tools::file_path_sans_ext(basename(script))
    on      <- if (model == "pt_null") character() else strsplit(sub("^pt_", "", model), "")[[1]]
    got     <- captured_build(script)
    sampled <- PT_EXPECTED[[model]]
    expect_setequal(pt_param_names(on), sampled)
    # the passed priors (intercept overrides + effects) are exactly the sampled parameters
    expect_setequal(names(got$extra_mu), sampled)
    expect_identical(names(got$extra_mu), names(got$extra_sd), label = model)
    expect_setequal(names(got$functions), c("TargetAtLoc", "SearchDifficulty", "PrevTargetAtLoc"))
  }
})

test_that("pt family: PrevTargetAtLoc enters exactly the parameters named in the script", {
  for (script in PT_SCRIPTS) {
    stem <- sub("^pt_", "", tools::file_path_sans_ext(basename(script)))
    on   <- if (stem == "null") character() else strsplit(stem, "")[[1]]
    got  <- captured_build(script)
    has_pt <- c(v = "PrevTargetAtLoc" %in% all.vars(got$v_formula),
                A = "PrevTargetAtLoc" %in% all.vars(got$A_formula),
                B = "PrevTargetAtLoc" %in% all.vars(got$B_formula))
    expect_setequal(names(has_pt)[has_pt], on)
  }
})

test_that("PT_PRIOR_SD_SCALE scales the effect SDs only (every script's build), never the intercepts", {
  expect_identical(names(PT_PRIOR_MU), names(PT_PRIOR_SD))
  expect_identical(names(PT_INTERCEPT_MU), names(PRIOR_MU))
  expect_identical(names(PT_INTERCEPT_SD), names(PRIOR_MU))
  base_mu <- pt_effect_priors(1)$mu
  expect_identical(pt_effect_priors(2)$mu, base_mu)
  withr::with_envvar(c(PT_PRIOR_SD_SCALE = "2"), for (script in PT_SCRIPTS) {
    got <- captured_build(script)
    fx <- setdiff(names(got$extra_sd), names(PT_INTERCEPT_SD))
    expect_equal(got$extra_sd[names(PT_INTERCEPT_SD)], PT_INTERCEPT_SD, label = basename(script))
    expect_equal(got$extra_sd[fx], PT_PRIOR_SD[fx] * 2, label = basename(script))
    expect_equal(got$extra_mu[names(PT_INTERCEPT_MU)], PT_INTERCEPT_MU, label = basename(script))
    expect_equal(got$extra_mu[fx], base_mu[fx], label = basename(script))
  })
})

# Reason: the scale reaches MODEL_NAME (parsed, not executed) and the priors by separate code paths; they must agree.
test_that("PT_PRIOR_SD_SCALE is normalised identically for MODEL_NAME and the priors; invalid values error", {
  null_script <- file.path(ROOT, "R", "fit", "pt_null.R")
  cases <- list(c("1", "", 1), c("1.0", "", 1), c("", "", 1), c("  ", "", 1), c("2", "_sd2", 2),
                c("2.0", "_sd2", 2), c(".5", "_sd0.5", 0.5), c("0.5", "_sd0.5", 0.5), c(" 2 ", "_sd2", 2),
                c("1e-1", "_sd0.1", 0.1))
  for (case in cases) {
    lbl <- sprintf("PT_PRIOR_SD_SCALE='%s'", case[[1]])
    withr::with_envvar(c(PT_PRIOR_SD_SCALE = case[[1]]), {
      expect_identical(model_script_name(null_script), paste0("pt_null", case[[2]]), label = lbl)
      expect_equal(pt_prior_sd_scale(), as.numeric(case[[3]]), label = lbl)
      expect_equal(pt_effect_priors()$sd, PT_PRIOR_SD * as.numeric(case[[3]]), label = lbl)
    })
  }
  for (bad in c("abc", "0", "-1", "NaN", "Inf", "1,5")) {
    withr::with_envvar(c(PT_PRIOR_SD_SCALE = bad), {
      expect_error(model_script_name(null_script), "positive number", label = bad)
      expect_error(pt_prior_sd_scale(), "positive number", label = bad)
      expect_error(pt_effect_priors(), "positive number", label = bad)
    })
  }
})

test_that("a prior-sensitivity scale gives each script a distinct MODEL_NAME, hidden from the default eval set", {
  withr::with_envvar(c(PT_PRIOR_SD_SCALE = "0.5"), {
    scaled <- vapply(PT_SCRIPTS, model_script_name, character(1))
    expect_true(all(grepl("_sd0.5$", scaled)))
    expect_false(anyDuplicated(scaled) > 0)
  })
  withr::with_envvar(c(PT_PRIOR_SD_SCALE = "1"),
                     expect_false(any(grepl("_sd", vapply(PT_SCRIPTS, model_script_name, character(1))))))
  dir <- withr::local_tempdir()
  file.create(file.path(dir, c("260101_pt_vB.rds", "260101_pt_vB_sd0.5.rds", "260101_pt_vB_sd2.rds")))
  expect_identical(discover_model_names(dir), "pt_vB")
  expect_silent(check_model_names(c("pt_vB", "pt_vB_sd0.5"), dir))   # explicit names bypass the exclusion
})

test_that("every pt script's MODEL_DATA_ARGS reads as the MIXED-free subset", {
  for (script in PT_SCRIPTS)
    expect_identical(model_data_args(script), list(difficulties = c("EASY", "DIFFICULT")), label = basename(script))
})


# Reason: step 0 relies on these summaries; a wrong window/choice computation would silently misjudge the priors.
test_that("summarise_prior_predictive: window share, quantiles and per-difficulty target proportion", {
  sim <- data.frame(rt = c(0.2, 0.5, 0.6, 1.2),
                    R = c(1, 2, 2, 2), S = rep(c("T,E,E,E", "E,T,E,E"), 2),
                    search_difficulty = c("EASY", "EASY", "DIFFICULT", "DIFFICULT"))
  s <- summarise_prior_predictive(sim, window = c(0.23, 1))
  expect_equal(s$prop_finite, 1)
  expect_equal(s$prop_in_window, 0.5)
  expect_equal(s$rt_median_in_window, 0.55)
  expect_equal(s$rt_q50, median(sim$rt))
  expect_equal(s$p_target_easy, 1)
  expect_equal(s$p_target_difficult, 0.5)
})

test_that("sample_prior_group_params: named mu and a symmetric positive-definite joint Sigma, seed-reproducible", {
  prior <- list(theta_mu_mean = c(a = 0, b = 1, c = 2), theta_mu_var = diag(c(1, 4, 1)), v = 2, A = c(0.3, 0.3, 0.3))
  set.seed(1); g1 <- sample_prior_group_params(prior)
  set.seed(1); g2 <- sample_prior_group_params(prior)
  expect_identical(g1, g2)
  expect_identical(names(g1$mu), c("a", "b", "c"))
  expect_identical(dimnames(g1$Sigma), list(c("a", "b", "c"), c("a", "b", "c")))
  expect_true(isSymmetric(g1$Sigma))
  expect_true(all(eigen(g1$Sigma, symmetric = TRUE, only.values = TRUE)$values > 0))
  expect_gt(abs(g1$Sigma[1, 2]), 0)   # joint draw: off-diagonals are not zero
  expect_no_error(sample_prior_group_params(modifyList(prior, list(A = 0.3))))   # scalar A
})

# Reason: the draw is the joint inverse-Wishart, so its variances must keep EMC2's
# IG(v/2, v/a), a ~ IG(1/2, 1/A^2) marginal (a drift here would silently change the prior predictive).
test_that("sample_prior_group_params: variance marginal matches InvGamma(v/2, v/a), a ~ InvGamma(1/2, 1/A^2)", {
  prior <- list(theta_mu_mean = c(a = 0, b = 0), theta_mu_var = diag(2), v = 2, A = c(0.3, 0.3))
  set.seed(7)
  n      <- 3000L
  drawn  <- vapply(seq_len(n), function(i) diag(sample_prior_group_params(prior)$Sigma)[[1]], numeric(1))
  a_half <- 1 / stats::rgamma(n, shape = 1 / 2, rate = 1 / 0.3^2)
  ref    <- 1 / stats::rgamma(n, shape = prior$v / 2, rate = prior$v / a_half)
  expect_gt(stats::ks.test(log(drawn), log(ref))$p.value, 0.001)
})
