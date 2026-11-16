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

# A fit saved under EMC2 3.4.1 must work under the installed version as-is: update2version() would
# truncate such an object's trial index, so the pipeline never migrates fits.
LEGACY <- readRDS(file.path(FIXTURES_DIR, "test_model_fitted_3.4.1.rds"))

test_that("log_lik_per_trial sums to EMC2's subject log-likelihood; the LL matrix is [samples x trials]; 3.4.1 fits need no migration", {
  expect_identical(attr(LEGACY, "emc2_version"), "3.4.1")
  expect_equal(.trial_counts(LEGACY), .trial_counts(FITTED))   # trial index intact

  for (fit_name in c("current", "legacy_3.4.1")) {
    fit         <- list(current = FITTED, legacy_3.4.1 = LEGACY)[[fit_name]]
    model_obj   <- fit[[1]]$model()
    pars_matrix <- .emc2_pars_matrix_fn()
    alpha       <- lapply(emc_get_pars(fit, selection = "alpha", return_mcmc = TRUE), as.matrix)
    n_trials    <- vapply(fit[[1]]$data, function(d) length(attr(d, "expand")), integer(1))

    emc2_ll <- function(i, s) {
      p_vec <- setNames(vapply(alpha, `[`, numeric(1), i, s), names(alpha))
      dadm  <- fit[[1]]$data[[s]]
      pars  <- pars_matrix(p_vec, dadm, model_obj)
      c(ours = sum(log_lik_per_trial(pars, dadm, model_obj)),
        emc2 = model_obj$log_likelihood(pars, dadm, model_obj))
    }
    for (i in c(1L, nrow(alpha[[1]]))) for (s in seq_along(SUBJ)) {
      ll <- emc2_ll(i, s)
      expect_equal(ll[["ours"]], ll[["emc2"]], label = sprintf("%s: sample %d, subject %d", fit_name, i, s))
    }

    ll_mat <- extract_log_lik_matrix(fit, max_samples = 4L)
    expect_equal(dim(ll_mat), c(4L, sum(n_trials)), label = fit_name)
    expect_equal(attr(ll_mat, "chain_id"), rep(1:2, each = 2L), label = fit_name)
    expect_true(all(is.finite(ll_mat)), label = fit_name)
    first_subj <- seq_len(n_trials[[1]])
    expect_equal(sum(ll_mat[1, first_subj]), emc2_ll(1L, 1L)[["emc2"]], label = fit_name)
  }
})


# =============================================================================
# eval/gof.R and eval/recovery.R end to end on real EMC2 objects
# =============================================================================

test_that("create_goodness_of_fit_table: conditional and joint ICs are both reported and internally consistent", {
  ic_cols <- c("EffectiveN", "DIC", "wDIC", "BPIC", "wBPIC", "mean_LL", "meanD", "Dmean", "minD")
  # Two different fits (same data and model, other draws); "first" also carries stale
  # cached ICs that compare() would reuse for any type unless they are stripped.
  stale <- FITTED
  attr(stale, "ICs") <- c(DIC = 1, BPIC = 1, EffectiveN = 1, meanD = 1, Dmean = 1, minD = 1)
  tbl <- create_goodness_of_fit_table(list(first = stale, second = LEGACY))

  expect_equal(tbl$model, c("first", "second"))
  for (i in 1:2) {   # a swapped or misaligned row would differ from the single-model computation
    single <- create_goodness_of_fit_table(setNames(list(list(FITTED, LEGACY)[[i]]), c("first", "second")[i]))
    shared <- setdiff(names(tbl), c("model", "wDIC_conditional", "wBPIC_conditional",
                                    "wDIC_joint", "wBPIC_joint"))
    expect_equal(unlist(tbl[i, shared]), unlist(single[1, shared]), label = tbl$model[i])
  }
  expect_false(isTRUE(all.equal(tbl$DIC_conditional[1], tbl$DIC_conditional[2])))
  expect_equal(tbl$num_params, rep(length(PARS), 2L))
  expect_true(all(c(paste0(ic_cols, "_conditional"), paste0(ic_cols, "_joint")) %in% names(tbl)))
  for (type in c("conditional", "joint")) {
    col <- function(x) tbl[[paste0(x, "_", type)]]
    expect_true(all(is.finite(unlist(tbl[paste0(ic_cols, "_", type)]))), label = type)
    expect_equal(col("DIC"),  col("meanD") + col("EffectiveN"), label = type)
    expect_equal(col("BPIC"), col("meanD") + 2 * col("EffectiveN"), label = type)
    expect_equal(col("mean_LL"), col("meanD") / -2, label = type)
    expect_true(all(col("minD") <= col("Dmean")), label = type)
    expect_equal(sum(col("wDIC")), 1, label = type)
  }
  # The joint IC adds the group-level density, so the two types must not be copies of each other.
  expect_false(isTRUE(all.equal(tbl$DIC_conditional, tbl$DIC_joint)))
  expect_false(isTRUE(all.equal(tbl$EffectiveN_conditional, tbl$EffectiveN_joint)))
})

test_that("create_loo_table: balanced chains, r_eff passed to loo, finite summary; incomparable trial sets rejected at the comparison", {
  loo_dir <- withr::local_tempdir()
  local_mocks(LOO_DIR = loo_dir)
  tbl <- suppressWarnings(quietly(suppressMessages(
    create_loo_table(list(first = FITTED, second = LEGACY), max_samples = 41L))))   # odd: floor(41 / 2) per chain
  for (i in 1:2) {   # each row equals the single-model computation, so a swap would fail
    single <- suppressWarnings(quietly(suppressMessages(
      create_loo_table(setNames(list(list(FITTED, LEGACY)[[i]]), c("first", "second")[i]), max_samples = 41L))))
    expect_equal(tbl$elpd_loo[i], single$elpd_loo, label = tbl$model[i])
  }
  expect_false(isTRUE(all.equal(tbl$elpd_loo[1], tbl$elpd_loo[2])))

  expect_equal(tbl$model, c("first", "second"))
  expect_true(all(is.finite(unlist(tbl[setdiff(names(tbl), c("model", "k_flag"))]))))
  expect_type(tbl$k_flag, "logical")
  expect_lt(abs(tbl$elpd_loo[1] - tbl$elpd_waic[1]), tbl$se_elpd_loo[1])   # WAIC and LOO agree loosely

  ll <- extract_log_lik_matrix(FITTED, max_samples = 41L)
  expect_equal(unname(table(attr(ll, "chain_id"))), unname(table(rep(1:2, each = 20L))))   # 20 draws per chain
  expect_equal(nrow(ll), 40L)

  saved <- readRDS(file.path(loo_dir, "first_loo.rds"))
  with_reff <- suppressWarnings(loo::loo(ll, r_eff = trial_relative_eff(ll)))
  no_reff   <- suppressWarnings(loo::loo(ll, r_eff = NA))
  expect_equal(saved$diagnostics$n_eff, with_reff$diagnostics$n_eff)
  expect_false(isTRUE(all.equal(saved$diagnostics$n_eff, no_reff$diagnostics$n_eff)))

  reordered <- lapply(FITTED, function(chain) { chain$data <- rev(chain$data); chain })   # same subjects, other order
  other <- suppressWarnings(quietly(suppressMessages(
    create_loo_table(list(first = FITTED, other = reordered), max_samples = 41L))))
  expect_equal(other$model, c("first", "other"))                       # per-model table is still produced
  expect_equal(attr(saved, "trial_counts"), .trial_counts(FITTED))
  expect_error(make_loo_comparison_df(list(first = saved, other = readRDS(file.path(loo_dir, "other_loo.rds")))),
               "differ in subjects")
  short <- suppressWarnings(loo::loo(ll[, seq_len(ncol(ll) / 2)], r_eff = NA))
  expect_error(make_loo_comparison_df(list(first = saved, short = short)), "different numbers of trials")
  expect_equal(make_loo_comparison_df(list(first = saved, second = saved))$elpd_diff, c(0, 0))
})

test_that("recovery_emc2_rows: order-invariant in true_alpha, coverage and RMSE match an independent computation, no device left open", {
  est   <- alpha_posterior_means(FITTED)
  truth <- est
  truth[2, ]          <- truth[2, ] + 50                       # subject 2 far outside every interval
  truth[1, c(1, 3)]   <- truth[1, c(1, 3)] + 50                # subject 1 outside for two parameters
  extra <- cbind(truth, a_constant = 0)
  shuffled <- extra[rev(rownames(extra)), sample(colnames(extra))]

  devices_before <- grDevices::dev.list()
  rows     <- recovery_emc2_rows(FITTED, truth, "m", 1L)
  rows_shf <- recovery_emc2_rows(FITTED, shuffled, "m", 1L)
  expect_identical(grDevices::dev.list(), devices_before)
  expect_equal(rows_shf, rows)
  expect_equal(rows$stats$parameter, PARS)
  expect_equal(rows$points$subject, rep(SUBJ, times = length(PARS)))

  alpha <- emc_get_pars(FITTED, selection = "alpha", stage = "sample", map = FALSE, return_mcmc = TRUE)
  for (p in PARS) {
    draws  <- as.matrix(alpha[[p]])[, SUBJ]
    bounds <- apply(draws, 2, quantile, probs = c(0.025, 0.975))
    inside <- bounds[1, ] < truth[SUBJ, p] & truth[SUBJ, p] < bounds[2, ]
    got    <- rows$points[rows$points$parameter == p, ]
    expect_equal(got$inside, unname(inside), label = p)
    expect_equal(rows$stats$coverage[rows$stats$parameter == p], 100 * mean(inside), label = p)
    expect_equal(rows$stats$rmse[rows$stats$parameter == p],
                 sqrt(mean((apply(draws, 2, median) - truth[SUBJ, p])^2)), label = p)
  }
  expect_true(any(rows$points$inside) && !all(rows$points$inside))   # the check is not vacuous
})
