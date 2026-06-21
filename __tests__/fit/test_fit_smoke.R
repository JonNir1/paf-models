.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)
library(EMC2)

# CI-only: skip unless TEST_LEVEL >= 3
if (as.integer(Sys.getenv("TEST_LEVEL", "1")) < 3L) {
  testthat::skip("Skipping fit smoke tests (set TEST_LEVEL=3 to run)")
}

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")       # fit_to_convergence, check_convergence
source_root("R/fit/helpers/recovery.R")      # extract_group_params, simulate_recovery_data
source_root("R/fit/fit_recovery_cloud.R")    # exposes run_recovery_fit()
source_root("R/fit/fit_ppc_cloud.R")         # exposes run_ppc_simulation()
source(file.path(ROOT, "__tests__", "fixtures", "test_model.R"))  # build_model(), MODEL_NAME

# Per-run temp dir so parallel CI runs don't collide.
SMOKE_DIR <- file.path(tempdir(), paste0("paf_smoke_", Sys.getpid()))
dir.create(SMOKE_DIR, recursive = TRUE)

# max_gd=Inf forces each EMC2 phase to exit after its minimum iteration count,
# preventing covariance degeneracy with tiny chains. Passed as init_stop_criteria
# to the warm-up fit() inside fit_to_convergence().
SMOKE_STOP_CRITERIA <- list(
  preburn = list(iter = 10L, max_gd = Inf),
  burn    = list(iter = 20L, max_gd = Inf),
  adapt   = list(iter = 10L, max_gd = Inf),
  sample  = list(iter = 20L, max_gd = Inf)
)

# Trivially-satisfied Rhat/ESS gates so convergence is decided purely by the
# sample-stage floor -- keeps smoke runtime deterministic regardless of chain
# quality. The sample floor (40) exceeds the warm-up sample count (20) so the
# extension loop is exercised on a fresh fit.
TRIVIAL_CC <- list(
  num_samples = 40L,
  mu          = list(max_rhat = 1e6, min_ess = 0),
  alpha       = list(max_rhat = 1e6, min_ess = 0)
)

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
data <- filter_data(raw,
                    min_rt               = MIN_SACCADE_CUTOFF,
                    max_rt               = MAX_SACCADE_CUTOFF,
                    allow_target_repeats = ALLOW_TARGET_REPEAT)


# =============================================================================
# Smoke A/B: the unified fit_to_convergence() entry point
# Two paths in one test:
#   res1 (fresh): warm up an unfitted model, then converge. EMC2's warm-up sample
#         stage already exceeds the trivial floor, so the pre-loop check passes
#         and the extension loop legitimately does NOT run (n_tries == 0). We do
#         NOT assert n_tries here -- whether the loop runs depends on EMC2's
#         warm-up iteration count, which is not ours to pin.
#   res2 (resume): feed the returned (already-sampling) model back in with a
#         floor ABOVE its current sample count, which deterministically forces
#         the extension loop to run -- this is what exercises the resume +
#         add-a-batch path.
# =============================================================================

smoke_fitted <- NULL  # set here, reused by smoke C/D

test_that("smoke A/B: fit_to_convergence fits a fresh model then resumes it", {
  m         <- build_model(data, n_chains = 2L)
  save_path <- file.path(SMOKE_DIR, "test_model_smoke.rds")

  # --- Fresh: warm up, then converge (loop may or may not run) ---
  res1 <- fit_to_convergence(
    m,
    convergence_criteria = TRIVIAL_CC,
    max_tries            = 3L,
    batch_size           = 20L,
    save_every           = 1L,
    save_path            = save_path,
    log_file             = file.path(SMOKE_DIR, "smoke_fit.log"),
    init_stop_criteria   = SMOKE_STOP_CRITERIA
  )

  expect_type(res1, "list")
  expect_setequal(names(res1),
                  c("model", "saved_path", "diagnostics", "n_tries",
                    "converged", "n_samples", "duration_min"))
  expect_type(res1$model, "list")
  expect_length(res1$model, 2L)
  expect_true(res1$converged)
  expect_gte(res1$n_samples, TRIVIAL_CC$num_samples)
  expect_true(file.exists(res1$saved_path))

  # --- Resume: floor set above current sample count => the loop MUST run ---
  resume_floor <- res1$n_samples + 20L
  res2 <- fit_to_convergence(
    res1$model,
    convergence_criteria = modifyList(TRIVIAL_CC, list(num_samples = resume_floor)),
    max_tries            = 3L,
    batch_size           = 20L,
    save_path            = file.path(SMOKE_DIR, "test_model_smoke_resume.rds"),
    log_file             = file.path(SMOKE_DIR, "smoke_fit_resume.log")
  )
  expect_true(res2$converged)
  expect_gte(res2$n_tries, 1L)                 # resume + extension loop ran
  expect_gt(res2$n_samples, res1$n_samples)    # the loop added sampling iters

  smoke_fitted <<- res1$model
})


# =============================================================================
# Smoke C: end-to-end recovery pipeline (fit_recovery_cloud.R::run_recovery_fit)
# Driven by the synthetic fitted model from smoke A/B -- no real fit required.
# Exercises extract -> simulate -> build -> fit_to_convergence.
#
# The smoke fit is tiny + under-converged, so its extracted Sigma is too diffuse:
# make_random_effects() draws extreme alpha and make_data() rejects >10% as
# out-of-bounds (flaky). We therefore inject group_params with the real means but
# a TAME diagonal Sigma so the chain runs deterministically. Production extracts
# Sigma from a well-converged fit (group_params = NULL) and does not hit this.
# =============================================================================

test_that("smoke C: run_recovery_fit completes end-to-end on the synthetic model", {
  skip_if(is.null(smoke_fitted), "smoke A/B did not produce a fitted model")

  gp <- extract_group_params(smoke_fitted)
  gp$Sigma <- diag(0.1, length(gp$mu))
  dimnames(gp$Sigma) <- list(names(gp$mu), names(gp$mu))

  result <- run_recovery_fit(
    extended_model    = smoke_fitted,
    template_data     = data,
    model_script_path = file.path(ROOT, "__tests__", "fixtures", "test_model.R"),
    recovery_name     = "test_model_smoke_recovery",
    log_file          = file.path(SMOKE_DIR, "smoke_C_recovery.log"),
    out_dir           = SMOKE_DIR,
    sim_seed          = 123L,
    group_params      = gp,
    convergence_criteria = TRIVIAL_CC,
    max_tries         = 3L,
    batch_size        = 20L,
    save_every        = 1L,
    init_stop_criteria = SMOKE_STOP_CRITERIA
  )

  expect_identical(result, "COMPLETE")

  # Side effects: true_alpha + recovered model .rds in SMOKE_DIR.
  outs <- list.files(SMOKE_DIR, pattern = "test_model_smoke_recovery.*\\.rds$",
                     full.names = TRUE)
  expect_true(any(grepl("true_alpha\\.rds$", outs)), label = "true_alpha rds saved")
  expect_true(length(outs) >= 2L, label = "recovered model rds saved alongside true_alpha")
})


# =============================================================================
# Smoke D: PPC simulation pipeline (fit_ppc_cloud.R::run_ppc_simulation)
# Also driven by the synthetic fitted model. No MCMC -- runs in seconds.
# =============================================================================

test_that("smoke D: run_ppc_simulation produces a list of data frames", {
  skip_if(is.null(smoke_fitted), "smoke A/B did not produce a fitted model")

  n_draws <- 5L
  result <- run_ppc_simulation(
    extended_model = smoke_fitted,
    template_data  = data,
    ppc_name       = "test_model_smoke",
    log_file       = file.path(SMOKE_DIR, "smoke_D_ppc.log"),
    out_dir        = SMOKE_DIR,
    n_draws        = n_draws,
    sim_seed       = RNG_SEED,
    name_suffix    = "_smoke"
  )

  expect_type(result, "list")
  expect_length(result, n_draws)
  for (i in seq_along(result)) {
    expect_s3_class(result[[i]], "data.frame")
    expect_true(nrow(result[[i]]) > 0L)
    expect_true(all(c("subjects", "rt", "R") %in% names(result[[i]])))
    expect_equal(nrow(result[[i]]), nrow(data))
  }

  out_files <- list.files(SMOKE_DIR, pattern = "test_model_smoke_ppc_smoke\\.rds$",
                          full.names = TRUE)
  expect_true(length(out_files) >= 1L, label = "ppc .rds saved to disk")
})
