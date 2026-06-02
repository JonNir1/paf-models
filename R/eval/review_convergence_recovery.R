#' =============================================================================
#' Step 2.9 -- Combined Convergence + Recovery Review (synthesis)
#'
#' Joins the convergence verdict (from R/eval/convergence.R -> convergence.rds)
#' with the recovery summaries (from R/eval/recovery.R) into a single per-model
#' decision table for the PI review, and renders the convergence summary figure.
#'
#' This is a SYNTHESIS step: it surfaces evidence; it does NOT pre-decide which
#' models survive (that is the PI checkpoint at 2.9). Writes
#' outputs/evaluation/review_2_9_summary.{rds,csv}.
#'
#' Prerequisites (run first, in order):
#'   source("R/eval/convergence.R")   # writes convergence.{rds,csv}
#'   source("R/eval/recovery.R")      # writes parameter_recovery/*.csv
#'
#' Run from the repo root:  source("R/eval/review_convergence_recovery.R")
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")
source_root("R/eval/helpers/io.R")
source_root("R/eval/helpers/plot.R")

MODEL_NAMES <- c("model1", "model2", "model4", "model5")


# ------------------------------
# Load inputs (fail loudly with guidance if a prerequisite is missing)

.need <- function(path, how) {
  if (!file.exists(path)) stop(sprintf("Missing %s.\n  -> run: %s", path, how))
  path
}

conv_table <- readRDS(.need(file.path(EVAL_DIR, "convergence.rds"),
                            'source("R/eval/convergence.R")'))
rec_dir    <- RECOVERY_EVAL_DIR
model_stats <- read.csv(.need(file.path(rec_dir, "recovery_model_stats.csv"),
                              'source("R/eval/recovery.R")'), stringsAsFactors = FALSE)
z_table     <- read.csv(.need(file.path(rec_dir, "recovery_zscores_contraction.csv"),
                              'source("R/eval/recovery.R")'), stringsAsFactors = FALSE)


# ------------------------------
# Per-model 2.9 decision table

.block_verdict <- function(model, block) {
  v <- conv_table$verdict[conv_table$model == model & conv_table$group == block]
  if (length(v) == 0) NA_character_ else v[1]
}

review <- do.call(rbind, lapply(MODEL_NAMES, function(mn) {
  zt <- z_table[z_table$model == mn, ]
  ms <- model_stats[model_stats$model == mn, ]
  data.frame(
    model              = mn,
    conv_mu            = .block_verdict(mn, "mu"),
    conv_alpha         = .block_verdict(mn, "alpha"),
    conv_sigma2        = .block_verdict(mn, "sigma2"),
    conv_correlation   = .block_verdict(mn, "correlation"),
    rec_r_full         = if (nrow(ms)) round(ms$r_all[1], 3)    else NA_real_,
    rec_rmse_full      = if (nrow(ms)) round(ms$rmse_all[1], 3) else NA_real_,
    rec_r_core         = if (nrow(ms)) round(ms$r_core[1], 3)    else NA_real_,
    rec_rmse_core      = if (nrow(ms)) round(ms$rmse_core[1], 3) else NA_real_,
    z_frac_gt2         = if (nrow(zt)) round(mean(abs(zt$z_score) > 2, na.rm = TRUE), 3) else NA_real_,
    mean_contraction   = if (nrow(zt)) round(mean(zt$contraction, na.rm = TRUE), 3)     else NA_real_,
    stringsAsFactors   = FALSE
  )
}))

save_eval_table(review, "review_2_9_summary")
message("\n--- Step 2.9 decision table ---")
print(review)


# ------------------------------
# Convergence summary figure for the deck

save_ggplot_png(plot_convergence_summary(conv_table),
                file.path(EVAL_DIR, "convergence_summary.png"))
message("\n===== review_convergence_recovery.R complete =====")
