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
# Smoke C: end-to-end recovery pipeline (fit_recovery_cloud.R::run_recovery_fit)
#
# Calls the production function with a subsetted real-data template so the
# make_data() pass is fast (~30 trials/subject keeps all 42 subjects so the
# subject-parameter draw still exercises the full MVN(mu, Sigma) loop).
#
# Skips when the real fitted .rds and the design matrix aren't present locally
# -- CI for L3 doesn't ship them and shouldn't have to.
#
# LINUX-FIRST: EMC2 chains run in parallel via fork on Linux. On Windows,
# get_core_args() forces cores_for_chains=1 (no fork), so the initial fit()
# and each extend step run fully sequentially. Even with subsetted data this
# can take 30+ min and may crash low-memory machines.
#
# Windows guardrail: Smoke C is skipped by default on Windows.
# To run it anyway:
#   - Non-interactively: set env var SMOKE_C_WINDOWS=1 before running
#   - Interactively:     you will be prompted to confirm
# =============================================================================

source_root("R/fit/fit_recovery_cloud.R")    # exposes run_recovery_fit()

EXTENDED_RDS <- file.path(ROOT, "outputs", "models", "fit_extend",
                          "260525_model1_extended.rds")
HAVE_REAL_INPUTS <- file.exists(EXTENDED_RDS) && file.exists(file.path(ROOT, DATA_FILE))

ON_WINDOWS <- .Platform$OS.type == "windows"
WINDOWS_APPROVED <- !ON_WINDOWS ||
  identical(Sys.getenv("SMOKE_C_WINDOWS"), "1") ||
  (interactive() && {
    ans <- readline(
      "Smoke C: EMC2 runs sequentially on Windows (30+ min, crash risk). Continue? [y/N] "
    )
    grepl("^[yY]", ans)
  })

test_that("smoke C: run_recovery_fit completes end-to-end on subsetted real data", {
  skip_if_not(HAVE_REAL_INPUTS,
              "smoke C needs the real extended .rds + design matrix locally")
  skip_if_not(WINDOWS_APPROVED,
              "smoke C skipped on Windows (set SMOKE_C_WINDOWS=1 or run interactively to override)")

  # Load real extended model + filter the design matrix, then subset to keep
  # all subjects but only ~30 trials each (~1.2k rows, ~1-2 min vs ~15 min full).
  extended_model <- readRDS(EXTENDED_RDS)
  raw            <- load_safe_csv(file.path(ROOT, DATA_FILE))
  template_full  <- filter_data(raw,
                                min_rt               = MIN_SACCADE_CUTOFF,
                                max_rt               = MAX_SACCADE_CUTOFF,
                                allow_target_repeats = ALLOW_TARGET_REPEAT)
  template_small <- template_full |>
    dplyr::group_by(subjects) |>
    dplyr::slice_head(n = 30) |>
    dplyr::ungroup()

  expect_equal(dplyr::n_distinct(template_small$subjects),
               dplyr::n_distinct(template_full$subjects))
  expect_lte(nrow(template_small), 30 * dplyr::n_distinct(template_full$subjects))

  # Loose stop_criteria so all EMC2 phases exit after iter=5 without waiting
  # for convergence. iter sets the minimum; max_gd=Inf disables the Gelman-Rubin
  # check, so each phase exits as soon as the minimum is reached.
  smoke_stop_criteria <- list(
    preburn = list(iter = 5L, max_gd = Inf),
    burn    = list(iter = 5L, max_gd = Inf),
    adapt   = list(iter = 5L, max_gd = Inf)
  )

  result <- run_recovery_fit(
    extended_model    = extended_model,
    template_data     = template_small,
    model_script_path = file.path(ROOT, "R", "fit", "model1.R"),
    recovery_name     = "model1_smoke_recovery",
    log_file          = file.path(SMOKE_DIR, "smoke_C_recovery.log"),
    out_dir           = SMOKE_DIR,
    sim_seed          = RECOVERY_BASE_SEED + 1L,
    fit_samples       = 5L,
    max_tries         = 1L,
    step_size         = 5L,
    save_every        = 1L,
    max_rhat_mu       = MAX_RHAT_MU_RECOVERY,
    min_ess_mu        = MIN_ESS_MU_RECOVERY,
    max_rhat_alpha    = MAX_RHAT_ALPHA_RECOVERY,
    min_ess_alpha     = MIN_ESS_ALPHA_RECOVERY,
    name_suffix       = "_smoke",
    fit_stop_criteria = smoke_stop_criteria
  )

  expect_identical(result, "COMPLETE")

  # Side-effect checks: true_alpha + initial-fit checkpoint .rds in SMOKE_DIR.
  outs <- list.files(SMOKE_DIR, pattern = "model1_smoke_recovery.*\\.rds$",
                     full.names = TRUE)
  expect_true(any(grepl("true_alpha\\.rds$", outs)),
              label = "true_alpha rds saved")
  expect_true(length(outs) >= 2L,
              label = "initial-fit checkpoint rds saved alongside true_alpha")
})
