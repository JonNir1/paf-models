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
#' All computation lives in R/eval/helpers/recovery.R; figures in helpers/plot.R.
#' Outputs land in RECOVERY_EVAL_DIR (outputs/evaluation/parameter_recovery/).
#'
#' Run from the repo root after downloading the recovery .rds from S3:
#'   source("R/eval/recovery.R")
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")              # utils -> config (RECOVERY_EVAL_DIR, dirs)
source_root("R/fit/helpers/recovery.R")          # extract_group_params (data-generating mu)
source_root("R/eval/helpers/recovery.R")         # recovery-eval computations
source_root("R/eval/helpers/plot.R")             # Plotly figures + save_plotly_png

RECOVERY_OUT_DIR <- RECOVERY_EVAL_DIR
if (!dir.exists(RECOVERY_OUT_DIR)) dir.create(RECOVERY_OUT_DIR, recursive = TRUE)

MODEL_NAMES <- discover_model_names()
N_SIMS      <- 3L


# =============================================================================
#  Load the latest converged recovery fit + true_alpha for a sim.
# =============================================================================

.latest <- function(dir, pattern) {
  files <- list.files(dir, pattern = pattern, full.names = TRUE)
  if (length(files) == 0L) return(NA_character_)
  files[which.max(as.Date(sub("_.*", "", basename(files)), format = "%y%m%d"))]
}

load_recovery_pair <- function(model_name, sim_index, dir = MODELS_RECOVERY_DIR) {
  rds <- .latest(dir, sprintf("^[0-9]{6}_%s_recovery_sim%d\\.rds$",
                              model_name, sim_index))
  ta  <- .latest(dir, sprintf("^[0-9]{6}_%s_recovery_sim%d_true_alpha\\.rds$",
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
pairs <- list()
for (mn in MODEL_NAMES) for (si in seq_len(N_SIMS)) {
  key <- sprintf("%s_sim%d", mn, si)
  pairs[[key]] <- tryCatch(load_recovery_pair(mn, si),
                           error = function(e) { message("  MISSING: ", e$message); NULL })
}
pairs <- Filter(Negate(is.null), pairs)
message(sprintf("Loaded %d / %d pairs.", length(pairs), length(MODEL_NAMES) * N_SIMS))

# Data-generating mu (from the ORIGINAL extended fit) + prior SDs, per model.
mu_true_by_model   <- list()
prior_sds_by_model <- list()
for (mn in MODEL_NAMES) {
  ext <- .latest(MODELS_FIT_DIR, sprintf("^[0-9]{6}_%s\\.rds$", mn))
  if (is.na(ext)) { message(sprintf("  no fit for %s; skipping", mn)); next }
  em <- readRDS(ext)
  mu_true_by_model[[mn]]   <- extract_group_params(em)$mu
  prior_sds_by_model[[mn]] <- get_prior_sds(em)
}


# =============================================================================
#  A. Population table   B. Subject points/stats   C. z-score/contraction
# =============================================================================

pop_rows <- list(); z_rows <- list(); subj_rows <- list()
for (p in pairs) {
  mn <- p$model_name; si <- p$sim_index
  if (is.null(mu_true_by_model[[mn]])) next
  mu_true   <- mu_true_by_model[[mn]]
  prior_sds <- prior_sds_by_model[[mn]]

  pop_rows[[length(pop_rows) + 1L]]   <- recovery_population_rows(p$model, mu_true, mn, si)
  z_rows[[length(z_rows) + 1L]]       <- recovery_zscore_rows(p$model, mu_true, prior_sds, mn, si)
  subj_rows[[length(subj_rows) + 1L]] <- recovery_subject_rows(p$model, p$true_alpha, mn, si)
}

pop_table   <- do.call(rbind, pop_rows)
z_table     <- do.call(rbind, z_rows)
subj_points <- do.call(rbind, subj_rows)
subj_points$identifiable <- flag_identifiable(subj_points$parameter)
subj_stats  <- recovery_subject_stats(subj_points)
subj_stats$identifiable <- flag_identifiable(subj_stats$parameter)

# Per-model summary over the full set AND the identifiable "core" subspace
# (excludes the StimulusAtLoc x SearchDifficulty partially-nested block; step 2.9).
model_stats <- recovery_model_summary(subj_stats)

write.csv(pop_table,   file.path(RECOVERY_OUT_DIR, "recovery_population_table.csv"),   row.names = FALSE)
write.csv(z_table,     file.path(RECOVERY_OUT_DIR, "recovery_zscores_contraction.csv"), row.names = FALSE)
write.csv(subj_stats,  file.path(RECOVERY_OUT_DIR, "recovery_subject_stats.csv"),      row.names = FALSE)
write.csv(model_stats, file.path(RECOVERY_OUT_DIR, "recovery_model_stats.csv"),        row.names = FALSE)
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
