library(testthat)

# CI-only: skip unless TEST_LEVEL >= 3
if (as.integer(Sys.getenv("TEST_LEVEL", "1")) < 3L) {
  testthat::skip("Skipping fit smoke tests (set TEST_LEVEL=3 to run)")
}

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/fit_recovery_cloud.R")    # run_recovery_fit + fitting/recovery helpers
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))      # SMOKE_STOP_CRITERIA, TRIVIAL_CC
source(file.path(ROOT, "__tests__", "fixtures", "test_model.R"))  # build_model(), MODEL_NAME

# Per-run temp dir so parallel CI runs don't collide.
SMOKE_DIR <- file.path(tempdir(), paste0("paf_smoke_", Sys.getpid()))
dir.create(SMOKE_DIR, recursive = TRUE)

data <- load_fixture_data()


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

smoke_fitted <- NULL  # set here, reused by smoke C

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
# The smoke fit is tiny + under-converged, so BOTH its extracted mu and Sigma are
# unreliable: make_random_effects() draws land >10% out of model bounds and
# make_data() rejects them (flaky). We therefore inject KNOWN-GOOD group_params
# (config means + tame diagonal Sigma) from the shared fixture helper -- the same
# in-bounds construction L2 uses. Production extracts from a well-converged fit
# (group_params = NULL) and does not hit this.
# =============================================================================

test_that("smoke C: run_recovery_fit completes end-to-end on the synthetic model", {
  skip_if(is.null(smoke_fitted), "smoke A/B did not produce a fitted model")

  gp <- test_group_params(extract_design(smoke_fitted))

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

# The PPC pipeline (former smoke D) runs at L2 on the committed fitted fixture:
# __tests__/models/test_fitted_fixture.R.
