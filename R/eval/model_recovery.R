#' =============================================================================
#' Model Recovery Analysis -- driver
#'
#' Can model selection tell the models apart? Data are simulated from each
#' generating model and refit with every candidate model (fit_recovery_cloud.R
#' with --fit-model-script, files `<gen>_recovery_sim<N>_fit_<candidate>.rds`;
#' the same-model fit `<gen>_recovery_sim<N>.rds` is the diagonal candidate). The
#' candidate with the highest median marginal likelihood (bridge sampling) is
#' "selected"; the generating x selected confusion matrix is the result.
#'
#' Marginal likelihoods are read from the MLL files in MODELS_BF_DIR (computed on
#' the cloud by scripts/run_bf.sh) and computed locally, slowly, only where
#' missing (BF_REPS repetitions) and only if ALLOW_LOCAL_MLL <- TRUE.
#'
#' Candidate set = every fitted model (discover_model_names()); N_SIMS simulations
#' per generating model (pre-settable, default 3). A missing fit is an error unless
#' ALLOW_PARTIAL_MODEL_RECOVERY <- TRUE is set before sourcing (then incomplete
#' generating x sim groups are skipped and listed). The same holds when a group's
#' candidates were not fit to identical simulated data (their true_alpha files,
#' incl. provenance attributes, must match).
#'
#' Writes (MODEL_RECOVERY_EVAL_DIR, outputs/evaluation/model_recovery/):
#'   model_recovery_mll.{rds,csv}        -- generating, sim, fitted, mll_median, mll_range, n_split_warnings
#'   model_recovery_selection.{rds,csv}  -- generating, sim, selected, correct, margin, spread
#'   model_recovery_confusion.{rds,csv}  -- generating, selected, n, prop
#'   model_recovery_confusion.png        -- heatmap of the above
#'
#' Run from the repo root:  source("R/eval/model_recovery.R")
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")                # MODEL_RECOVERY_EVAL_DIR, BF_REPS
source_root("R/eval/helpers/io.R")                 # recovery_stem, latest_dated_file, save_eval_table
source_root("R/eval/helpers/bf.R")                 # get_mll
source_root("R/eval/helpers/model_recovery.R")     # select_by_mll, confusion_table
source_root("R/eval/helpers/plot.R")               # plot_confusion_matrix, save_ggplot_png

if (!exists("MODEL_NAMES")) MODEL_NAMES <- discover_model_names()   # pre-settable (e.g. a subset)
check_model_names(MODEL_NAMES)
if (length(MODEL_NAMES) < 2L)
  stop(sprintf("Model recovery needs at least two fitted models in %s.", MODELS_FIT_DIR))
if (!exists("N_SIMS")) N_SIMS <- 3L
if (!exists("ALLOW_PARTIAL_MODEL_RECOVERY")) ALLOW_PARTIAL_MODEL_RECOVERY <- FALSE


# =============================================================================
#  Median MLL of every generating x sim x candidate fit
# =============================================================================

#' Latest dated recovery file of `stem` (`<stem>` + `suffix`), or NA.
recovery_file <- function(stem, suffix = "") {
  latest_dated_file(MODELS_RECOVERY_DIR, sprintf("^[0-9]{6}_%s%s\\.rds$", regex_escape(stem), suffix))
}

mll_rows <- list()
problems <- character(0)
for (gen in MODEL_NAMES) for (si in seq_len(N_SIMS)) {
  fits <- vapply(MODEL_NAMES, function(cand) recovery_file(recovery_stem(gen, si, cand)), character(1))
  alphas <- setNames(lapply(MODEL_NAMES, function(cand) {
    path <- recovery_file(recovery_stem(gen, si, cand), "_true_alpha")
    if (is.na(path)) NULL else readRDS(path)
  }), MODEL_NAMES)
  reason <- recovery_group_problem(fits, alphas)
  if (!is.null(reason)) {
    problems <- c(problems, sprintf("%s sim %d: %s", gen, si, reason))
    next
  }
  for (cand in MODEL_NAMES) {
    record <- get_mll(fits[[cand]], BF_REPS)
    mll_rows[[length(mll_rows) + 1L]] <- data.frame(
      generating = gen, sim = si, fitted = cand, mll_median = stats::median(record$mll),
      mll_range = diff(range(record$mll)), n_split_warnings = record$n_split_warnings,
      stringsAsFactors = FALSE)
  }
}

if (length(problems) > 0L && !ALLOW_PARTIAL_MODEL_RECOVERY) {
  stop(sprintf(paste0("Incomplete model-recovery set (%d problem group(s)); ",
                      "set ALLOW_PARTIAL_MODEL_RECOVERY <- TRUE to proceed:\n  %s"),
               length(problems), paste(problems, collapse = "\n  ")))
}
if (length(problems) > 0L)
  warning(sprintf("Skipped %d generating x sim group(s):\n  %s",
                  length(problems), paste(problems, collapse = "\n  ")), call. = FALSE)
if (length(mll_rows) == 0L) stop("No complete generating x sim group among the model-recovery fits.")
mll_df <- do.call(rbind, mll_rows)


# =============================================================================
#  Selection, confusion matrix, figure
# =============================================================================

selection <- select_by_mll(mll_df, MODEL_NAMES)
confusion <- confusion_table(selection, MODEL_NAMES)

save_eval_table(mll_df,     "model_recovery_mll",       dir = MODEL_RECOVERY_EVAL_DIR)
save_eval_table(selection,  "model_recovery_selection", dir = MODEL_RECOVERY_EVAL_DIR)
save_eval_table(confusion,  "model_recovery_confusion", dir = MODEL_RECOVERY_EVAL_DIR)
message("Confusion matrix (generating x selected, counts):")
print(xtabs(n ~ generating + selected, confusion))

save_ggplot_png(plot_confusion_matrix(confusion),
                file.path(MODEL_RECOVERY_EVAL_DIR, "model_recovery_confusion.png"),
                width = 8, height = 6)
message("===== model_recovery.R complete; outputs in ", MODEL_RECOVERY_EVAL_DIR, " =====")
