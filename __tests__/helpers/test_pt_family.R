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
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))

PT_SCRIPTS <- list.files(file.path(ROOT, "R", "fit"), pattern = "^pt_.*[.]R$", full.names = TRUE)

# Parameter names a design with these formulas samples, enumerated here with
# model.matrix on a tiny factor grid (independent of pt_param_names()).
expected_names <- function(formulas) {
  grid <- expand.grid(TargetAtLoc = factor(c(FALSE, TRUE)),
                      SearchDifficulty = factor(c("EASY", "DIFFICULT"), levels = c("EASY", "DIFFICULT")),
                      PrevTargetAtLoc = factor(c(FALSE, TRUE)))
  nm <- unlist(Map(function(f, par) {
    cols <- colnames(model.matrix(delete.response(terms(f)), grid))
    ifelse(cols == "(Intercept)", par, paste0(par, "_", cols))
  }, formulas, c("v", "sv", "B", "A")), use.names = FALSE)
  c(setdiff(nm, names(CONSTANTS)), "t0")
}

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
test_that("pt family: every parameter a script's formulas sample has a prior, and no unused prior is passed", {
  for (script in PT_SCRIPTS) {
    got     <- captured_build(script)
    sampled  <- expected_names(unname(got[c("v_formula", "sv_formula", "B_formula", "A_formula")]))
    prior_mu <- c(PRIOR_MU, got$extra_mu)
    prior_sd <- c(PRIOR_SD, got$extra_sd)
    lbl <- basename(script)
    expect_true(all(sampled %in% names(prior_mu)), label = lbl)
    expect_true(all(sampled %in% names(prior_sd)), label = lbl)
    expect_true(all(names(got$extra_mu) %in% sampled), label = lbl)
    expect_identical(names(got$extra_mu), names(got$extra_sd), label = lbl)
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

test_that("PT_PRIOR_SD_SCALE scales the effect SDs only and rejects non-positive values", {
  base   <- pt_effect_priors(1)
  scaled <- pt_effect_priors(2)
  expect_equal(scaled$sd, base$sd * 2)
  expect_identical(scaled$mu, base$mu)
  expect_identical(names(PT_PRIOR_MU), names(PT_PRIOR_SD))
  expect_identical(PRIOR_SD, c(v = 2, B = 1, A = 1, t0 = 1))   # intercept SDs are never scaled
  withr::with_envvar(c(PT_PRIOR_SD_SCALE = "0"),
                     expect_error(sys.source(file.path(ROOT, "R", "fit", "helpers", "pt_family.R"),
                                             envir = new.env(parent = globalenv())), "positive"))
})

test_that("a prior-sensitivity scale gives each script a distinct MODEL_NAME", {
  withr::with_envvar(c(PT_PRIOR_SD_SCALE = "0.5"), {
    scaled <- vapply(PT_SCRIPTS, model_script_name, character(1))
    expect_true(all(grepl("_sd0.5$", scaled)))
    expect_false(anyDuplicated(scaled) > 0)
  })
  withr::with_envvar(c(PT_PRIOR_SD_SCALE = "1"),
                     expect_false(any(grepl("_sd", vapply(PT_SCRIPTS, model_script_name, character(1))))))
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

test_that("sample_prior_group_params: named mu and a positive-definite diagonal Sigma, seed-reproducible", {
  prior <- list(theta_mu_mean = c(a = 0, b = 1), theta_mu_var = diag(c(1, 4)), v = 2, A = c(0.3, 0.3))
  set.seed(1); g1 <- sample_prior_group_params(prior)
  set.seed(1); g2 <- sample_prior_group_params(prior)
  expect_identical(g1, g2)
  expect_identical(names(g1$mu), c("a", "b"))
  expect_identical(dimnames(g1$Sigma), list(c("a", "b"), c("a", "b")))
  expect_true(all(diag(g1$Sigma) > 0))
})
