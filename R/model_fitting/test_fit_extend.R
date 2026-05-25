#' =============================================================================
#' Smoke test for fit_extend.R
#' Verifies the new extend_model() pipeline end-to-end with tiny settings so
#' it can run on a laptop in ~10-20 minutes without overloading the CPU.
#'
#' What this tests:
#'   - readRDS() loads the model
#'   - run_emc(max_tries=1, step_size=N) adds N iterations per try
#'   - check_block_convergence() extracts Rhat/ESS via EMC2::check()
#'   - per-try logging is correctly written to a dedicated log file
#'   - extended model is saved with the new naming convention
#'
#' What this does NOT verify:
#'   - that models will actually converge under the asymmetric criteria
#'     (10 added iterations is far too few; expect "Max tries exhausted")
#'
#' To run:        Rscript R/model_fitting/test_fit_extend.R
#' Cleanup after: delete emc2_models/log_test_smoke.txt and
#'                emc2_models/<YYMMDD>_model2_extended.rds
#' =============================================================================

library(EMC2)
source("R/model_fitting/helpers/fitting.R")  # defines extend_model() and config globals

result <- extend_model(
  rds_filename   = "260409_model2.rds",         # smallest fitted model on disk
  log_file       = "emc2_models/log_test_smoke.txt",
  max_tries      = 2,                           # tiny - 2 extension attempts
  step_size      = 5                            # tiny - 5 iterations per attempt
  # other args (thresholds, EXTENDED_FIT_SAMPLES) default to globals from config.R
  # parallelism is auto-detected by get_core_args() inside extend_model()
)

cat("\n========================================\n")
cat("Smoke-test summary\n")
cat("========================================\n")
cat(sprintf("  converged:    %s\n", result$converged))
cat(sprintf("  tries used:   %d\n", result$n_tries))
cat(sprintf("  runtime (m):  %.2f\n", result$duration_min))
cat(sprintf("  saved to:     %s\n", result$saved_path))
cat("\nFinal block diagnostics:\n")
cat(sprintf("  mu:    Rhat=%.4f  ESS=%.0f\n",
            result$diagnostics$mu_max_rhat,    result$diagnostics$mu_min_ess))
cat(sprintf("  alpha: Rhat=%.4f  ESS=%.0f\n",
            result$diagnostics$alpha_max_rhat, result$diagnostics$alpha_min_ess))
cat("\nFull per-try log:  emc2_models/log_test_smoke.txt\n")
