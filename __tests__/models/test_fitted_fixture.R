#' =============================================================================
#' Level-2 tests on the committed fitted fixture (__tests__/fixtures/
#' test_model_fitted.rds): real EMC2 calls on a real (tiny, unconverged) fit,
#' with no MCMC and no design() build. Skips with a regenerate hint when the
#' fixture's EMC2 major.minor differs from the installed one.
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
library(EMC2)   # the eval helpers call check() / get_pars() unqualified
source_root("R/fit/fit_ppc_cloud.R")   # run_ppc_simulation + recovery helpers
source_root("R/eval/eval_config.R")
source_root("R/eval/helpers/convergence.R")
source_root("R/eval/helpers/recovery.R")
source_root("R/eval/helpers/gof.R")
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))

FITTED <- load_fitted_fixture()
DATA   <- load_fixture_data()


test_that("run_ppc_simulation simulates n_draws datasets with the template's trial structure", {
  dir     <- withr::local_tempdir()
  n_draws <- 5L
  sims <- quietly(run_ppc_simulation(FITTED, DATA, ppc_name = "test_model",
                                     log_file = file.path(dir, "ppc.log"), out_dir = dir,
                                     n_draws = n_draws, sim_seed = RNG_SEED))

  expect_length(sims, n_draws)
  for (sim in sims) {
    expect_s3_class(sim, "data.frame")
    expect_equal(nrow(sim), nrow(DATA))
    expect_identical(as.character(sim$subjects), as.character(DATA$subjects))
    expect_identical(levels(sim$R), levels(DATA$R))
    expect_true(all(is.finite(sim$rt) & sim$rt > 0))
  }
  expect_identical(readRDS(list.files(dir, "_test_model_ppc\\.rds$", full.names = TRUE)), sims)
})


# =============================================================================
# EMC2 object contracts the pipeline relies on (the "empirically confirmed
# 3.4.1 shapes" in CLAUDE.md, re-verified on 3.5.0), checked on a real fit
# =============================================================================

SUBJ  <- names(FITTED[[1]]$data)
PARS  <- names(FITTED[[1]]$prior$theta_mu_mean)

test_that("check() blocks are read by both the fit gate and the eval convergence table", {
  chk <- quietly(suppressWarnings(emc_check(FITTED, selection = c("mu", "sigma2", "alpha", "correlation"),
                                            plot_worst = FALSE)))
  for (g in c("mu", "sigma2", "alpha", "correlation")) {
    de <- .block_rhat_ess(chk, g)
    expect_true(is.finite(de$max_rhat) && is.finite(de$min_ess), label = g)
  }
  expect_length(check_block_values(chk, "alpha", 1), length(SUBJ) * length(PARS))
  expect_length(check_block_values(chk, "mu", 2), length(PARS))
  expect_true(check_convergence(FITTED, TRIVIAL_CC)$converged)

  tbl <- add_convergence_verdict(create_convergence_table(list(test_model = FITTED)))
  expect_setequal(tbl$group, c("mu", "sigma2", "alpha", "correlation"))
  expect_equal(tbl$n_params[tbl$group == "alpha"], length(SUBJ) * length(PARS))
  expect_true(all(tbl$verdict[tbl$group %in% c("sigma2", "correlation")] == "descriptive"))
  expect_true(all(tbl$verdict[tbl$group %in% c("mu", "alpha")] %in% c("pass", "marginal", "fail")))
})

test_that("get_pars(alpha) is parameter-keyed [samples x subjects]; the prior holds theta_mu_var", {
  alpha <- emc_get_pars(FITTED, selection = "alpha", stage = "sample", map = FALSE, return_mcmc = TRUE)
  expect_equal(names(alpha), PARS)
  m <- as.matrix(alpha[[1]])
  expect_equal(colnames(m), SUBJ)
  expect_equal(nrow(m), .sample_iters(FITTED) * length(FITTED))

  expect_setequal(names(emc_sampled_pars(extract_design(FITTED))), PARS)
  expect_true(all(PARS %in% names(PRIOR_MU)))

  V <- FITTED[[1]]$prior$theta_mu_var
  expect_equal(dim(V), c(length(PARS), length(PARS)))
  expect_equal(get_prior_sds(FITTED), setNames(sqrt(diag(V)), PARS))

  means <- alpha_posterior_means(FITTED)
  expect_equal(dimnames(means), list(SUBJ, PARS))
})

test_that("flattened correlations follow the column-major lower triangle extract_group_params assumes", {
  cors <- emc_get_pars(FITTED, selection = "correlation", stage = "sample",
                       flatten = TRUE, return_mcmc = TRUE)
  lt   <- which(lower.tri(diag(length(PARS))), arr.ind = TRUE)
  expect_equal(colnames(as.matrix(cors[[1]])), paste(PARS[lt[, 1]], PARS[lt[, 2]], sep = "."))

  gp <- extract_group_params(FITTED)
  expect_equal(names(gp$mu), PARS)
  expect_equal(dimnames(gp$Sigma), list(PARS, PARS))
  expect_true(isSymmetric(gp$Sigma))
  expect_true(all(eigen(gp$Sigma, only.values = TRUE)$values > 0))
})


# =============================================================================
# Per-trial log-likelihood (the LOO / WAIC basis) vs EMC2's own likelihood
# =============================================================================

test_that("log_lik_per_trial sums to EMC2's subject log-likelihood; the LL matrix is [samples x trials]", {
  model_obj   <- FITTED[[1]]$model()
  pars_matrix <- .emc2_pars_matrix_fn()
  alpha       <- lapply(emc_get_pars(FITTED, selection = "alpha", return_mcmc = TRUE), as.matrix)
  n_trials    <- vapply(FITTED[[1]]$data, function(d) length(attr(d, "expand")), integer(1))

  emc2_ll <- function(i, s) {
    p_vec <- setNames(vapply(alpha, `[`, numeric(1), i, s), names(alpha))
    dadm  <- FITTED[[1]]$data[[s]]
    pars  <- pars_matrix(p_vec, dadm, model_obj)
    c(ours = sum(log_lik_per_trial(pars, dadm, model_obj)),
      emc2 = model_obj$log_likelihood(pars, dadm, model_obj))
  }
  for (i in c(1L, nrow(alpha[[1]]))) for (s in seq_along(SUBJ)) {
    ll <- emc2_ll(i, s)
    expect_equal(ll[["ours"]], ll[["emc2"]], label = sprintf("sample %d, subject %d", i, s))
  }

  ll_mat <- extract_log_lik_matrix(FITTED, max_samples = 4L)
  expect_equal(dim(ll_mat), c(4L, sum(n_trials)))
  expect_equal(attr(ll_mat, "chain_id"), rep(1:2, each = 2L))
  expect_true(all(is.finite(ll_mat)))
  first_subj <- seq_len(n_trials[[1]])
  expect_equal(sum(ll_mat[1, first_subj]), emc2_ll(1L, 1L)[["emc2"]])
})
