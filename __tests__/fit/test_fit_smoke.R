.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)
library(EMC2)

# CI-only: skip unless TEST_LEVEL >= 3
if (as.integer(Sys.getenv("TEST_LEVEL", "1")) < 3L) {
  testthat::skip("Skipping fit smoke tests (set TEST_LEVEL=3 to run)")
}

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")     # transitively brings config + fit_config
source_root("R/fit/helpers/recovery.R")    # extract_group_params, simulate_recovery_data
source_root("R/fit/model1.R")              # provides build_model()


# Shared smoke-test state: smoke A output is reused by smoke B.
# Use a per-run temp directory so parallel CI runs don't collide.
SMOKE_DIR <- file.path(tempdir(), paste0("paf_smoke_", Sys.getpid()))
dir.create(SMOKE_DIR, recursive = TRUE)

raw  <- load_safe_csv(file.path(ROOT, "__tests__", "fixtures", "sample_data.csv"))
data <- filter_data(raw,
                    min_rt               = MIN_SACCADE_CUTOFF,
                    max_rt               = MAX_SACCADE_CUTOFF,
                    allow_target_repeats = ALLOW_TARGET_REPEAT)


# =============================================================================
# Smoke A: fit_initial path
# Builds model1 with n_chains=2 and fits for 5 iterations.
# =============================================================================

smoke_rds_path <- NULL  # set by smoke A, consumed by smoke B

test_that("smoke A: fit() returns a list of length n_chains", {
  m <- build_model(data, n_chains = 2L)
  fitted <- fit(m,
                iter             = 5L,
                max_tries        = 2L,
                step_size        = 5L,
                cores_for_chains = 1L,
                cores_per_chain  = 1L)
  expect_type(fitted, "list")
  expect_length(fitted, 2L)

  # Save for smoke B
  smoke_rds_path <<- save_model(fitted, "model1_smoke", SMOKE_DIR)
})

test_that("smoke A: each chain has a non-empty samples slot", {
  skip_if(is.null(smoke_rds_path), "smoke A did not produce a model")
  fitted <- readRDS(smoke_rds_path)
  for (i in seq_along(fitted)) {
    expect_true(length(fitted[[i]]$samples) > 0,
                label = sprintf("chain %d has samples", i))
  }
})

test_that("smoke A: saved .rds file exists and round-trips", {
  skip_if(is.null(smoke_rds_path), "smoke A did not produce a model")
  expect_true(file.exists(smoke_rds_path))
  restored <- readRDS(smoke_rds_path)
  expect_type(restored, "list")
  expect_length(restored, 2L)
})


# =============================================================================
# Smoke B: extend_model path
# Resumes the model saved in smoke A for 2 tries of 5 iterations each.
# =============================================================================

test_that("smoke B: extend_model returns a list with all expected keys", {
  skip_if(is.null(smoke_rds_path), "smoke A did not produce a model")

  rds_filename <- basename(smoke_rds_path)
  result <- extend_model(
    rds_filename  = rds_filename,
    log_file      = file.path(SMOKE_DIR, "smoke_extend.log"),
    models_dir    = SMOKE_DIR,
    min_num_samples = 1L,
    max_tries     = 2L,
    step_size     = 5L,
    max_rhat_mu   = MAX_RHAT_MU,
    min_ess_mu    = MIN_ESS_MU,
    max_rhat_alpha  = MAX_RHAT_ALPHA,
    min_ess_alpha   = MIN_ESS_ALPHA
  )

  expect_type(result, "list")
  expect_setequal(names(result),
                  c("model", "saved_path", "diagnostics", "n_tries",
                    "converged", "duration_min"))
})

test_that("smoke B: extended .rds file is written to disk", {
  skip_if(is.null(smoke_rds_path), "smoke A did not produce a model")

  rds_filename <- basename(smoke_rds_path)
  result <- extend_model(
    rds_filename  = rds_filename,
    log_file      = file.path(SMOKE_DIR, "smoke_extend2.log"),
    models_dir    = SMOKE_DIR,
    min_num_samples = 1L,
    max_tries     = 2L,
    step_size     = 5L,
    max_rhat_mu   = MAX_RHAT_MU,
    min_ess_mu    = MIN_ESS_MU,
    max_rhat_alpha  = MAX_RHAT_ALPHA,
    min_ess_alpha   = MIN_ESS_ALPHA
  )

  expect_true(file.exists(result$saved_path))
  expect_lte(result$n_tries, 2L)
})

test_that("smoke B: diagnostics list has all convergence keys", {
  skip_if(is.null(smoke_rds_path), "smoke A did not produce a model")

  rds_filename <- basename(smoke_rds_path)
  result <- extend_model(
    rds_filename  = rds_filename,
    log_file      = file.path(SMOKE_DIR, "smoke_extend3.log"),
    models_dir    = SMOKE_DIR,
    min_num_samples = 1L,
    max_tries     = 2L,
    step_size     = 5L,
    max_rhat_mu   = MAX_RHAT_MU,
    min_ess_mu    = MIN_ESS_MU,
    max_rhat_alpha  = MAX_RHAT_ALPHA,
    min_ess_alpha   = MIN_ESS_ALPHA
  )

  diag_keys <- c("converged", "mu_converged", "alpha_converged",
                 "mu_max_rhat", "mu_min_ess", "alpha_max_rhat", "alpha_min_ess")
  expect_setequal(names(result$diagnostics), diag_keys)
})


# =============================================================================
# Smoke C: fit_recovery_cloud.R path
# Mirrors the inner loop of fit_recovery_cloud.R end-to-end at tiny scale:
#   extract_group_params -> simulate_recovery_data -> build_model -> fit
# Uses the model fitted in Smoke A/B as the "extended" input.
# =============================================================================

# Shared state across Smoke C tests
recovery_group_params <- NULL
recovery_sim_result   <- NULL
recovery_fitted       <- NULL

test_that("smoke C: extract_group_params returns mu (named numeric) and Sigma (PD matrix)", {
  skip_if(is.null(smoke_rds_path), "smoke A did not produce a model")
  fitted <- readRDS(smoke_rds_path)

  recovery_group_params <<- extract_group_params(fitted)

  expect_type(recovery_group_params, "list")
  expect_setequal(names(recovery_group_params), c("mu", "Sigma"))
  expect_type(recovery_group_params$mu, "double")
  expect_named(recovery_group_params$mu)
  expect_true(is.matrix(recovery_group_params$Sigma))
  expect_equal(nrow(recovery_group_params$Sigma),
               ncol(recovery_group_params$Sigma))
  expect_equal(nrow(recovery_group_params$Sigma),
               length(recovery_group_params$mu))
  # PD check (per-sample averaging guarantees this in principle; smoke checks it
  # is actually delivered for a tiny fit).
  eig <- eigen(recovery_group_params$Sigma, only.values = TRUE)$values
  expect_true(all(eig > 0),
              label = sprintf("Sigma min eigenvalue (%.4g) > 0", min(eig)))
})

test_that("smoke C: simulate_recovery_data returns data + subject_pars matching template", {
  skip_if(is.null(recovery_group_params), "smoke C step 1 did not produce group_params")
  fitted <- readRDS(smoke_rds_path)

  recovery_sim_result <<- simulate_recovery_data(
    model         = fitted,
    group_params  = recovery_group_params,
    template_data = data,
    seed          = 101L
  )

  expect_type(recovery_sim_result, "list")
  expect_setequal(names(recovery_sim_result), c("data", "subject_pars"))
  expect_s3_class(recovery_sim_result$data, "data.frame")
  expect_equal(nrow(recovery_sim_result$data), nrow(data))
  expect_true(is.matrix(recovery_sim_result$subject_pars))
})

test_that("smoke C: fresh build_model + fit on simulated data returns list of length n_chains", {
  skip_if(is.null(recovery_sim_result), "smoke C step 2 did not produce sim data")

  fresh_model <- build_model(recovery_sim_result$data, n_chains = 2L)
  recovery_fitted <<- fit(
    fresh_model,
    iter             = 5L,
    max_tries        = 2L,
    step_size        = 5L,
    cores_for_chains = 1L,
    cores_per_chain  = 1L
  )
  expect_type(recovery_fitted, "list")
  expect_length(recovery_fitted, 2L)
})

test_that("smoke C: refit on simulated data saves and round-trips via .rds", {
  skip_if(is.null(recovery_fitted), "smoke C step 3 did not produce a fit")

  saved <- save_model(recovery_fitted, "model1_smoke_recovery", SMOKE_DIR)
  expect_true(file.exists(saved))
  restored <- readRDS(saved)
  expect_type(restored, "list")
  expect_length(restored, 2L)
})
