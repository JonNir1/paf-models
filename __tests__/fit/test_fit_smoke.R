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

# Shared stop_criteria: max_gd=Inf forces each EMC2 phase to exit after its
# minimum iteration count, preventing covariance degeneracy with tiny chains.
SMOKE_STOP_CRITERIA <- list(
  preburn = list(iter = 10L, max_gd = Inf),
  burn    = list(iter = 20L, max_gd = Inf),
  adapt   = list(iter = 10L, max_gd = Inf),
  sample  = list(iter = 20L, max_gd = Inf)
)

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
                cores_per_chain  = 1L,
                stop_criteria    = SMOKE_STOP_CRITERIA)
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
    rds_filename         = rds_filename,
    log_file             = file.path(SMOKE_DIR, "smoke_extend.log"),
    source_dir           = SMOKE_DIR,
    models_dir           = SMOKE_DIR,
    extended_fit_samples = 1L,
    max_tries            = 2L,
    step_size            = 5L,
    max_rhat_mu          = MAX_RHAT_MU,
    min_ess_mu           = MIN_ESS_MU,
    max_rhat_alpha       = MAX_RHAT_ALPHA,
    min_ess_alpha        = MIN_ESS_ALPHA
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
    rds_filename         = rds_filename,
    log_file             = file.path(SMOKE_DIR, "smoke_extend2.log"),
    source_dir           = SMOKE_DIR,
    models_dir           = SMOKE_DIR,
    extended_fit_samples = 1L,
    max_tries            = 2L,
    step_size            = 5L,
    max_rhat_mu          = MAX_RHAT_MU,
    min_ess_mu           = MIN_ESS_MU,
    max_rhat_alpha       = MAX_RHAT_ALPHA,
    min_ess_alpha        = MIN_ESS_ALPHA
  )

  expect_true(file.exists(result$saved_path))
  expect_lte(result$n_tries, 2L)
})

test_that("smoke B: diagnostics list has all convergence keys", {
  skip_if(is.null(smoke_rds_path), "smoke A did not produce a model")

  rds_filename <- basename(smoke_rds_path)
  result <- extend_model(
    rds_filename         = rds_filename,
    log_file             = file.path(SMOKE_DIR, "smoke_extend3.log"),
    source_dir           = SMOKE_DIR,
    models_dir           = SMOKE_DIR,
    extended_fit_samples = 1L,
    max_tries            = 2L,
    step_size            = 5L,
    max_rhat_mu          = MAX_RHAT_MU,
    min_ess_mu           = MIN_ESS_MU,
    max_rhat_alpha       = MAX_RHAT_ALPHA,
    min_ess_alpha        = MIN_ESS_ALPHA
  )

  diag_keys <- c("converged", "mu_converged", "alpha_converged",
                 "mu_max_rhat", "mu_min_ess", "alpha_max_rhat", "alpha_min_ess")
  expect_setequal(names(result$diagnostics), diag_keys)
})

test_that("smoke B: extend_model skips loop when model already meets all criteria", {
  skip_if(is.null(smoke_rds_path), "smoke A did not produce a model")

  # Trivially-satisfied thresholds (Rhat < 100, ESS > 0) guarantee the
  # pre-loop convergence check passes for any fitted model, regardless of
  # actual chain quality. Combined with extended_fit_samples = 1L the sample
  # floor is also immediately met, so the extension loop must be skipped.
  rds_filename <- basename(smoke_rds_path)
  log_file     <- file.path(SMOKE_DIR, "smoke_extend_preconverged.log")

  result <- extend_model(
    rds_filename         = rds_filename,
    log_file             = log_file,
    source_dir           = SMOKE_DIR,
    models_dir           = SMOKE_DIR,
    extended_fit_samples = 1L,
    max_tries            = 5L,
    step_size            = 5L,
    max_rhat_mu          = 100.0,
    min_ess_mu           = 0L,
    max_rhat_alpha       = 100.0,
    min_ess_alpha        = 0L
  )

  expect_equal(result$n_tries, 0L)
  expect_true(result$converged)
  expect_true(any(grepl("Already converged", readLines(log_file))))
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
# Runtime: bounded stop_criteria (max_gd=Inf) makes all EMC2 phases exit after
# their minimum iteration count, so total runtime is deterministic on all
# platforms (~7-10 min on Windows with cores_for_chains=1).
# =============================================================================

source_root("R/fit/fit_recovery_cloud.R")    # exposes run_recovery_fit()

EXTENDED_RDS <- file.path(ROOT, "outputs", "models", "fit_extend",
                          "260525_model1_extended.rds")
HAVE_REAL_INPUTS <- file.exists(EXTENDED_RDS) && file.exists(file.path(ROOT, DATA_FILE))

test_that("smoke C: run_recovery_fit completes end-to-end on subsetted real data", {
  skip_if_not(HAVE_REAL_INPUTS,
              "smoke C needs the real extended .rds + design matrix locally")

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

  result <- run_recovery_fit(
    extended_model    = extended_model,
    template_data     = template_small,
    model_script_path = file.path(ROOT, "R", "fit", "model1.R"),
    recovery_name     = "model1_smoke_recovery",
    log_file          = file.path(SMOKE_DIR, "smoke_C_recovery.log"),
    out_dir           = SMOKE_DIR,
    sim_seed          = RECOVERY_BASE_SEED + 1L,
    fit_samples       = 5L,
    max_tries         = 2L,
    step_size         = 10L,
    save_every        = 1L,
    max_rhat_mu       = MAX_RHAT_MU_RECOVERY,
    min_ess_mu        = MIN_ESS_MU_RECOVERY,
    max_rhat_alpha    = MAX_RHAT_ALPHA_RECOVERY,
    min_ess_alpha     = MIN_ESS_ALPHA_RECOVERY,
    name_suffix       = "_smoke",
    fit_stop_criteria = SMOKE_STOP_CRITERIA
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
