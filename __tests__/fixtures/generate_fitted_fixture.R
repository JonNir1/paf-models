#' =============================================================================
#' Regenerate __tests__/fixtures/test_model_fitted.rds: the synthetic test model
#' fit with the bounded smoke settings (tiny MCMC, NOT converged). L2 contract
#' tests load it instead of fitting, so rerun this after an EMC2 major/minor
#' upgrade or a change to the test model, then commit the .rds.
#'
#' Run from the repo root (~1 h on Windows, mostly EMC2 cluster start-up):
#'   R_LIBS_USER=<lib> Rscript __tests__/fixtures/generate_fitted_fixture.R
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")
source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "__tests__", "fixtures", "common.R"))
source(file.path(FIXTURES_DIR, "test_model.R"))

RNGkind(RNG_KIND)
set.seed(RNG_SEED)

fit <- fit_to_convergence(
  build_model(load_fixture_data(), n_chains = 2L),
  convergence_criteria = TRIVIAL_CC,
  max_tries            = 3L,
  batch_size           = 20L,
  init_stop_criteria   = SMOKE_STOP_CRITERIA
)
if (!fit$converged) stop("Fixture fit did not reach the sample floor.")

model <- fit$model
attr(model, "emc2_version") <- as.character(utils::packageVersion("EMC2"))
saveRDS(model, FITTED_FIXTURE, compress = "xz")
cat(sprintf("Wrote %s: %.2f MB, %d sample iters, EMC2 %s\n", FITTED_FIXTURE,
            file.size(FITTED_FIXTURE) / 2^20, fit$n_samples, attr(model, "emc2_version")))
