# Run Smoke D only (PPC simulation, no MCMC).
.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)
library(EMC2)

ROOT <- Sys.getenv("PAF_REPO_ROOT", getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/fit/helpers/fitting.R")
source_root("R/fit/helpers/recovery.R")
source_root("R/fit/fit_ppc_cloud.R")     # exposes run_ppc_simulation()

SMOKE_DIR <- file.path(tempdir(), paste0("paf_smoke_d_", Sys.getpid()))
dir.create(SMOKE_DIR, recursive = TRUE)
cat("Smoke D output dir:", SMOKE_DIR, "\n")

# outputs/ and data/ live in the main checkout (getwd()), not the worktree (ROOT).
MAIN_DIR     <- getwd()
EXTENDED_RDS <- file.path(MAIN_DIR, "outputs", "models", "fit_extend",
                           "260525_model1_extended.rds")
HAVE_REAL_INPUTS <- file.exists(EXTENDED_RDS) &&
  file.exists(file.path(MAIN_DIR, DATA_DIR, "exp1", "Exp1_clean.csv"))

test_that("smoke D: run_ppc_simulation produces a list of data frames", {
  skip_if_not(HAVE_REAL_INPUTS,
              "smoke D needs the real extended .rds + design matrix locally")

  extended_model <- readRDS(EXTENDED_RDS)
  template_full  <- load_data(min_rt               = MIN_SACCADE_CUTOFF,
                              max_rt               = MAX_SACCADE_CUTOFF,
                              allow_target_repeats = ALLOW_TARGET_REPEAT)
  template_small <- template_full |>
    dplyr::group_by(subjects) |>
    dplyr::slice_head(n = 30) |>
    dplyr::ungroup()

  n_draws <- 5L
  result <- run_ppc_simulation(
    extended_model = extended_model,
    template_data  = template_small,
    ppc_name       = "model1_smoke",
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
    expect_equal(nrow(result[[i]]), nrow(template_small))
  }

  out_files <- list.files(SMOKE_DIR, pattern = "model1_smoke_ppc_smoke\\.rds$",
                          full.names = TRUE)
  expect_true(length(out_files) >= 1L, label = "ppc .rds saved to disk")
  cat("Output files:", paste(basename(out_files), collapse = ", "), "\n")
})
