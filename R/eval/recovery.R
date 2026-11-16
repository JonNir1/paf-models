#' =============================================================================
#' Parameter Recovery Analysis (step 2.5 / 2.9) -- driver
#'
#' Loads the converged recovery fits (one .rds per model x sim) and their true
#' subject parameters, then produces three review artifacts:
#'
#'   A. Population table  -- true vs estimated mu per parameter (Strickland 2026).
#'   B. Subject scatter   -- estimated vs true alpha; RMSE + Pearson r per model.
#'   C. z-score/contraction -- posterior z vs contraction (Schad et al. 2021).
#'
#' Plus EMC2's own per-sim recovery statistics (recovery_emc2_stats: Pearson,
#' Spearman, RMSE, 95% coverage; posterior MEDIAN vs truth, one row per model x
#' sim x parameter) and a pooled `coverage95` column on recovery_subject_stats.
#'
#' All computation lives in R/eval/helpers/recovery.R; figures in helpers/plot.R.
#' Outputs land in RECOVERY_EVAL_DIR (outputs/evaluation/parameter_recovery/).
#'
#' Run from the repo root after downloading the recovery .rds from S3:
#'   source("R/eval/recovery.R")
#' Non-interactive, tolerating missing pairs:
#'   Rscript -e "ALLOW_PARTIAL_RECOVERY <- TRUE; source('R/eval/recovery.R')"
#' Model scripts are parsed, not executed, for their STRUCTURAL_UNIDENTIFIABLE_PATTERN
#' (top-level assignment, self-contained RHS). Each script is found by its declared
#' MODEL_NAME (any file name, unique within the directory) in MODEL_SCRIPT_DIR
#' (default R/fit); pre-set it to override. Never downgraded
#' by ALLOW_PARTIAL_RECOVERY.
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")              # utils -> config (RECOVERY_EVAL_DIR, dirs)
source_root("R/fit/helpers/recovery.R")          # extract_group_params (data-generating mu)
source_root("R/eval/helpers/recovery.R")         # recovery-eval computations
source_root("R/eval/helpers/io.R")               # save_eval_table
source_root("R/eval/helpers/plot.R")             # Plotly figures + save_plotly_png

RECOVERY_OUT_DIR <- RECOVERY_EVAL_DIR
if (!dir.exists(RECOVERY_OUT_DIR)) dir.create(RECOVERY_OUT_DIR, recursive = TRUE)

MODEL_NAMES <- discover_model_names()
N_SIMS      <- 3L

# Per-model structural-unidentifiability patterns; any error here is fatal.
UNIDENTIFIABLE_PATTERNS <- vapply(MODEL_NAMES, model_unidentifiable_pattern, character(1))

# Set ALLOW_PARTIAL_RECOVERY <- TRUE before sourcing to proceed with missing or
# unreadable recovery pairs / source fits; by default they are an error.
if (!exists("ALLOW_PARTIAL_RECOVERY")) ALLOW_PARTIAL_RECOVERY <- FALSE


# =============================================================================
#  Load the latest converged recovery fit + true_alpha for a sim.
# =============================================================================

load_recovery_pair <- function(model_name, sim_index, dir = MODELS_RECOVERY_DIR) {
  rds <- latest_dated_file(dir, sprintf("^[0-9]{6}_%s_recovery_sim%d\\.rds$",
                                        model_name, sim_index))
  ta  <- latest_dated_file(dir, sprintf("^[0-9]{6}_%s_recovery_sim%d_true_alpha\\.rds$",
                                        model_name, sim_index))
  if (is.na(rds) || is.na(ta)) {
    stop(sprintf("Missing recovery fit or true_alpha for %s sim%d in %s",
                 model_name, sim_index, dir))
  }
  list(model = readRDS(rds), true_alpha = readRDS(ta),
       model_name = model_name, sim_index = sim_index)
}


# =============================================================================
#  Load all available pairs; cache data-generating mu + prior SDs per model.
# =============================================================================

message("Loading recovery fits...")
pairs   <- list()
problems <- character(0)
for (mn in MODEL_NAMES) for (si in seq_len(N_SIMS)) {
  key <- sprintf("%s_sim%d", mn, si)
  pairs[[key]] <- tryCatch(load_recovery_pair(mn, si), error = function(e) {
    # An ambiguous latest file is a data problem, never a skippable missing pair.
    if (grepl("^Ambiguous latest file", conditionMessage(e))) {
      stop(sprintf("%s: %s", key, conditionMessage(e)), call. = FALSE)
    }
    message("  MISSING: ", conditionMessage(e))
    problems <<- c(problems, sprintf("%s: %s", key, conditionMessage(e)))
    NULL
  })
}
pairs <- Filter(Negate(is.null), pairs)
message(sprintf("Loaded %d / %d pairs.", length(pairs), length(MODEL_NAMES) * N_SIMS))

# Data-generating mu (from the ORIGINAL extended fit) + prior SDs, per model.
mu_true_by_model   <- list()
prior_sds_by_model <- list()
for (mn in MODEL_NAMES) {
  ext <- latest_dated_file(MODELS_FIT_DIR, model_rds_pattern(mn))
  if (is.na(ext)) {
    message(sprintf("  no fit for %s; skipping", mn))
    problems <- c(problems, sprintf("%s: no source fit in %s", mn, MODELS_FIT_DIR))
    next
  }
  em <- readRDS(ext)
  mu_true_by_model[[mn]]   <- extract_group_params(em)$mu
  prior_sds_by_model[[mn]] <- get_prior_sds(em)
}

if (length(problems) > 0L && !ALLOW_PARTIAL_RECOVERY) {
  stop(sprintf("Incomplete recovery set (%d problem(s)); set ALLOW_PARTIAL_RECOVERY <- TRUE to proceed:
  %s",
               length(problems), paste(problems, collapse = "
  ")))
}


# =============================================================================
#  A. Population table   B. Subject points/stats   C. z-score/contraction
# =============================================================================

pop_rows <- list(); z_rows <- list(); subj_rows <- list(); emc2_rows <- list()
for (p in pairs) {
  mn <- p$model_name; si <- p$sim_index
  if (is.null(mu_true_by_model[[mn]])) next
  mu_true   <- mu_true_by_model[[mn]]
  prior_sds <- prior_sds_by_model[[mn]]

  pop_rows[[length(pop_rows) + 1L]]   <- recovery_population_rows(p$model, mu_true, mn, si)
  z_rows[[length(z_rows) + 1L]]       <- recovery_zscore_rows(p$model, mu_true, prior_sds, mn, si)
  subj_rows[[length(subj_rows) + 1L]] <- recovery_subject_rows(p$model, p$true_alpha, mn, si)
  emc2_rows[[length(emc2_rows) + 1L]] <- recovery_emc2_rows(p$model, p$true_alpha, mn, si)
}

pop_table   <- do.call(rbind, pop_rows)
z_table     <- do.call(rbind, z_rows)
subj_points <- do.call(rbind, subj_rows)
subj_points$identifiable <- flag_identifiable(subj_points$parameter, subj_points$model, UNIDENTIFIABLE_PATTERNS)
emc2_stats  <- do.call(rbind, lapply(emc2_rows, `[[`, "stats"))
emc2_points <- do.call(rbind, lapply(emc2_rows, `[[`, "points"))
subj_stats  <- add_coverage95(recovery_subject_stats(subj_points), emc2_points)
subj_stats$identifiable <- flag_identifiable(subj_stats$parameter, subj_stats$model, UNIDENTIFIABLE_PATTERNS)

# Per-model summary over the full set AND the identifiable "core" subspace
# (excludes each model's declared structurally-unidentifiable parameters; step 2.9).
model_stats <- recovery_model_summary(subj_stats, UNIDENTIFIABLE_PATTERNS)

write.csv(pop_table,   file.path(RECOVERY_OUT_DIR, "recovery_population_table.csv"),   row.names = FALSE)
write.csv(z_table,     file.path(RECOVERY_OUT_DIR, "recovery_zscores_contraction.csv"), row.names = FALSE)
write.csv(subj_stats,  file.path(RECOVERY_OUT_DIR, "recovery_subject_stats.csv"),      row.names = FALSE)
write.csv(model_stats, file.path(RECOVERY_OUT_DIR, "recovery_model_stats.csv"),        row.names = FALSE)
save_eval_table(emc2_stats, "recovery_emc2_stats", dir = RECOVERY_OUT_DIR)
message("Saved recovery tables to ", RECOVERY_OUT_DIR)
message("Per-model recovery (full vs identifiable core):")
print(model_stats)


# =============================================================================
#  Figures (Plotly -> PNG, HTML fallback if kaleido missing)
# =============================================================================

save_ggplot_png(plot_recovery_scatter(subj_points, model_stats),
                file.path(RECOVERY_OUT_DIR, "recovery_subject_scatter.png"))
save_ggplot_png(plot_zscore_contraction(z_table),
                file.path(RECOVERY_OUT_DIR, "recovery_zscore_contraction.png"))
message("===== recovery.R complete; outputs in ", RECOVERY_OUT_DIR, " =====")
