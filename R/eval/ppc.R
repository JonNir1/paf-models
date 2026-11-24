#' =============================================================================
#' Posterior Predictive Check Analysis (step 4) -- driver
#'
#' Loads the posterior predictive simulation outputs produced by fit_ppc_cloud.R
#' (each active model with T=PPC_N_DRAWS simulated datasets) and produces:
#'
#'   A. Distribution fit      -- per-subject KS + BH FDR
#'   B. Choice proportions    -- T / D / E fractions: predicted vs observed
#'      by the PPC_GROUP_VARS cells (default experiment x cue_size x search_difficulty)
#'   C. Marginal QPF          -- 10/25/50/75/90th-percentile RT by condition:
#'      predicted ribbon (90% CI) vs observed points
#'   D. QPF by response type  -- same as C but stratified by T/D/E
#'      (Strickland et al. 2026 paper 2 Figs 14-15 style)
#'   E. Defective CDFs        -- p(RT <= t, R=r) reconstructed from D + B
#'      (Stevenson et al. 2026 paper 1 Figs 6/9 canonical EMC2 visualization)
#'
#' All computation lives in R/eval/helpers/ppc.R; save helpers in helpers/plot.R.
#' Outputs land in PPC_EVAL_DIR (outputs/evaluation/ppc/). The condition cells and
#' the figures' x variables follow PPC_GROUP_VARS (eval_config.R; pre-settable).
#' Each model's observed data are loaded with its script's MODEL_DATA_ARGS (script
#' found by declared MODEL_NAME in MODEL_SCRIPT_DIR, default R/fit).
#'
#' Run from the repo root after downloading the ppc .rds files from S3:
#'   source("R/eval/ppc.R")
#' Non-interactive, tolerating missing ppc fits:
#'   Rscript -e "ALLOW_PARTIAL_PPC <- TRUE; source('R/eval/ppc.R')"
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")      # PPC_EVAL_DIR, PPC_MODELS_DIR, PPC_N_DRAWS, ...
source_root("R/eval/helpers/ppc.R")      # compute_* + plot_ppc_*
source_root("R/eval/helpers/plot.R")     # save_ggplot_png
source_root("R/helpers/data.R")          # load_model_data, model_data_args

if (!dir.exists(PPC_EVAL_DIR)) dir.create(PPC_EVAL_DIR, recursive = TRUE)

# Active set = every fitted model. A model without a PPC .rds is an error unless
# ALLOW_PARTIAL_PPC <- TRUE is set before sourcing (then it is skipped).
MODEL_NAMES <- discover_model_names()
if (!exists("ALLOW_PARTIAL_PPC")) ALLOW_PARTIAL_PPC <- FALSE


# =============================================================================
#  Find the latest ppc .rds for a model
# =============================================================================

.latest_ppc <- function(model_name, dir = PPC_MODELS_DIR) {
  latest_dated_file(dir, sprintf("^[0-9]{6}_%s_ppc\\.rds$", model_name))
}


# =============================================================================
#  Observed data: per model (its script's MODEL_DATA_ARGS), loaded once per distinct subset
# =============================================================================

.observed_data <- local({
  cache <- list()
  function(model_name) {
    script <- find_model_script(model_name, MODEL_SCRIPT_DIR)
    key    <- paste(deparse(model_data_args(script)), collapse = "")
    if (is.null(cache[[key]])) {
      message(sprintf("Loading observed data for %s...", model_name))
      cache[[key]] <<- load_model_data(script)
      message(sprintf("Observed data: %d trials, %d subjects",
                      nrow(cache[[key]]), dplyr::n_distinct(cache[[key]]$subjects)))
    }
    cache[[key]]
  }
})


# =============================================================================
#  Compute all analyses per model (single pass -- loads each RDS once)
# =============================================================================

message("Running PPC evaluation...")

# A failing metric is recorded here and reported after every metric has run.
metric_failures <- character(0)
missing_ppc     <- character(0)
.try_metric <- function(model_name, metric, expr) {
  tryCatch(expr, error = function(e) {
    message(sprintf("    %s ERROR: %s", metric, conditionMessage(e)))
    metric_failures <<- c(metric_failures,
                          sprintf("%s / %s: %s", model_name, metric, conditionMessage(e)))
    NULL
  })
}
has_rows <- function(df) !is.null(df) && nrow(df) > 0L

dist_rows     <- list()
choice_rows   <- list()
qpf_rows      <- list()
qpf_resp_rows <- list()

for (mn in MODEL_NAMES) {
  rds_path <- .latest_ppc(mn)
  if (is.na(rds_path)) {
    message(sprintf("  MISSING: no ppc .rds found for %s in %s", mn, PPC_MODELS_DIR))
    missing_ppc <- c(missing_ppc, mn)
    next
  }
  message(sprintf("  Loading PPC sims for %s: %s", mn, basename(rds_path)))
  ppc_list <- readRDS(rds_path)
  message(sprintf("    %d draws loaded", length(ppc_list)))
  obs_data <- .observed_data(mn)

  dist_rows[[mn]]     <- .try_metric(mn, "dist_stats",
                                     compute_dist_stats(ppc_list, obs_data, mn))
  choice_rows[[mn]]   <- .try_metric(mn, "choice_proportions",
                                     compute_choice_proportions(ppc_list, obs_data, mn, group_vars = PPC_GROUP_VARS))
  qpf_rows[[mn]]      <- .try_metric(mn, "qpf_table",
                                     compute_qpf_table(ppc_list, obs_data, mn, group_vars = PPC_GROUP_VARS))
  qpf_resp_rows[[mn]] <- .try_metric(mn, "qpf_by_response",
                                     compute_qpf_table(ppc_list, obs_data, mn, by_response = TRUE,
                                                      group_vars = PPC_GROUP_VARS))
  rm(ppc_list)   # free memory before next model
}

if (length(metric_failures) > 0L) {
  stop(sprintf("PPC metric failure(s), as <model> / <metric>: <message>:
  %s", paste(metric_failures, collapse = "
  ")))
}

if (length(missing_ppc) > 0L && !ALLOW_PARTIAL_PPC) {
  stop(sprintf("No ppc .rds in %s for: %s; set ALLOW_PARTIAL_PPC <- TRUE to proceed without them.",
               PPC_MODELS_DIR, paste(missing_ppc, collapse = ", ")))
}

dist_rows     <- Filter(Negate(is.null), dist_rows)
choice_rows   <- Filter(Negate(is.null), choice_rows)
qpf_rows      <- Filter(Negate(is.null), qpf_rows)
qpf_resp_rows <- Filter(Negate(is.null), qpf_resp_rows)

if (length(dist_rows) == 0L) stop("No PPC results computed -- check that .rds files exist in PPC_MODELS_DIR.")


# =============================================================================
#  Bind and save tables
# =============================================================================

dist_df    <- do.call(rbind, dist_rows)
choice_df  <- do.call(rbind, choice_rows)
qpf_df     <- do.call(rbind, qpf_rows)
qpf_resp_df <- if (length(qpf_resp_rows) > 0L) do.call(rbind, qpf_resp_rows) else NULL

write.csv(dist_df,   file.path(PPC_EVAL_DIR, "ppc_dist_stats.csv"),        row.names = FALSE)
write.csv(choice_df, file.path(PPC_EVAL_DIR, "ppc_choice_proportions.csv"), row.names = FALSE)
write.csv(qpf_df,    file.path(PPC_EVAL_DIR, "ppc_qpf.csv"),               row.names = FALSE)

saveRDS(dist_df,   file.path(PPC_EVAL_DIR, "ppc_dist_stats.rds"))
saveRDS(choice_df, file.path(PPC_EVAL_DIR, "ppc_choice_proportions.rds"))
saveRDS(qpf_df,    file.path(PPC_EVAL_DIR, "ppc_qpf.rds"))

if (!is.null(qpf_resp_df)) {
  write.csv(qpf_resp_df, file.path(PPC_EVAL_DIR, "ppc_qpf_by_response.csv"), row.names = FALSE)
  saveRDS(qpf_resp_df,   file.path(PPC_EVAL_DIR, "ppc_qpf_by_response.rds"))
}

message("Saved PPC tables to ", PPC_EVAL_DIR)

# Per-model KS FDR summary
fdr_summary <- aggregate(fdr_pass ~ model, dist_df,
                         FUN = function(x) mean(x, na.rm = TRUE))
names(fdr_summary)[2] <- "frac_fdr_pass"
message("Per-model FDR pass fraction (KS test, BH):")
print(fdr_summary)


# =============================================================================
#  Figures
# =============================================================================

# A. Distribution fit stats
save_ggplot_png(plot_ppc_dist_stats(dist_df),
                file.path(PPC_EVAL_DIR, "ppc_dist_stats.png"))

# x variables = the grouping variables other than experiment. File-name tags: the
# default cue_size / search_difficulty keep their historical "cue" / "difficulty".
x_vars <- setdiff(PPC_GROUP_VARS, "experiment")
.tag   <- function(x) switch(x, cue_size = "cue", search_difficulty = "difficulty", x)

# B. Choice proportions
if (has_rows(choice_df)) {
  for (x in x_vars)
    save_ggplot_png(plot_ppc_choice(choice_df, x_var = x),
                    file.path(PPC_EVAL_DIR, sprintf("ppc_choice_%s.png", .tag(x))))
}

# C. Marginal QPF
if (has_rows(qpf_df)) {
  for (x in x_vars)
    save_ggplot_png(plot_ppc_qpf(qpf_df, x_var = x),
                    file.path(PPC_EVAL_DIR, sprintf("ppc_qpf_%s.png", .tag(x))),
                    width = 12, height = 10)
}

# D. QPF by response type
if (has_rows(qpf_resp_df)) {
  for (x in x_vars)
    save_ggplot_png(plot_ppc_qpf_by_response(qpf_resp_df, x_var = x),
                    file.path(PPC_EVAL_DIR, sprintf("ppc_qpf_resp_%s.png", .tag(x))),
                    width = 14, height = 10)
}

# E. Defective CDFs (requires both qpf_resp_df and choice_df)
if (has_rows(qpf_resp_df) && has_rows(choice_df)) {
  for (x in x_vars)
    save_ggplot_png(plot_ppc_cdf(qpf_resp_df, choice_df, x_facet = x, group_vars = PPC_GROUP_VARS),
                    file.path(PPC_EVAL_DIR, sprintf("ppc_cdf_%s.png", .tag(x))),
                    width = 14, height = 8)
}

message("===== ppc.R complete; outputs in ", PPC_EVAL_DIR, " =====")
