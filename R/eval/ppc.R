#' =============================================================================
#' Posterior Predictive Check Analysis (step 4) -- driver
#'
#' Loads the posterior predictive simulation outputs produced by fit_ppc_cloud.R
#' (4 models, each with T=PPC_N_DRAWS simulated datasets) and produces:
#'
#'   A. Distribution fit      -- per-subject KS + Anderson-Darling + BH FDR
#'   B. Choice proportions    -- T / D / E fractions: predicted vs observed
#'      by cue_size and search_difficulty
#'   C. Marginal QPF          -- 10/25/50/75/90th-percentile RT by condition:
#'      predicted ribbon (90% CI) vs observed points
#'   D. QPF by response type  -- same as C but stratified by T/D/E
#'      (Strickland et al. 2026 paper 2 Figs 14-15 style)
#'   E. Defective CDFs        -- p(RT <= t, R=r) reconstructed from D + B
#'      (Stevenson et al. 2026 paper 1 Figs 6/9 canonical EMC2 visualization)
#'
#' All computation lives in R/eval/helpers/ppc.R; save helpers in helpers/plot.R.
#' Outputs land in PPC_EVAL_DIR (outputs/evaluation/ppc/).
#'
#' Run from the repo root after downloading the ppc .rds files from S3:
#'   source("R/eval/ppc.R")
#' =============================================================================

library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")      # PPC_EVAL_DIR, PPC_MODELS_DIR, PPC_N_DRAWS, ...
source_root("R/eval/helpers/ppc.R")      # compute_* + plot_ppc_*
source_root("R/eval/helpers/plot.R")     # save_ggplot_png
source_root("R/helpers/data.R")          # load_safe_csv, filter_data

if (!dir.exists(PPC_EVAL_DIR)) dir.create(PPC_EVAL_DIR, recursive = TRUE)

MODEL_NAMES <- c("model1", "model2", "model4", "model5")


# =============================================================================
#  Find the latest ppc .rds for a model
# =============================================================================

.latest_ppc <- function(model_name, dir = PPC_MODELS_DIR) {
  pattern <- sprintf("^[0-9]{6}_%s_ppc\\.rds$", model_name)
  files   <- list.files(dir, pattern = pattern, full.names = TRUE)
  if (length(files) == 0L) return(NA_character_)
  files[which.max(as.Date(sub("_.*", "", basename(files)), format = "%y%m%d"))]
}


# =============================================================================
#  Load observed data
# =============================================================================

message("Loading observed data...")
raw_data  <- load_safe_csv(DATA_FILE)
obs_data  <- filter_data(raw_data,
                          min_rt               = MIN_SACCADE_CUTOFF,
                          max_rt               = MAX_SACCADE_CUTOFF,
                          allow_target_repeats = ALLOW_TARGET_REPEAT)
message(sprintf("Observed data: %d trials, %d subjects",
                nrow(obs_data), dplyr::n_distinct(obs_data$subjects)))


# =============================================================================
#  Compute all analyses per model (single pass -- loads each RDS once)
# =============================================================================

message("Running PPC evaluation...")

dist_rows     <- list()
choice_rows   <- list()
qpf_rows      <- list()
qpf_resp_rows <- list()

for (mn in MODEL_NAMES) {
  rds_path <- .latest_ppc(mn)
  if (is.na(rds_path)) {
    message(sprintf("  MISSING: no ppc .rds found for %s in %s", mn, PPC_MODELS_DIR))
    next
  }
  message(sprintf("  Loading PPC sims for %s: %s", mn, basename(rds_path)))
  ppc_list <- readRDS(rds_path)
  message(sprintf("    %d draws loaded", length(ppc_list)))

  dist_rows[[mn]] <- tryCatch(
    compute_dist_stats(ppc_list, obs_data, mn),
    error = function(e) { message("    dist_stats ERROR: ", e$message); NULL }
  )
  choice_rows[[mn]] <- tryCatch(
    compute_choice_proportions(ppc_list, obs_data, mn),
    error = function(e) { message("    choice_proportions ERROR: ", e$message); NULL }
  )
  qpf_rows[[mn]] <- tryCatch(
    compute_qpf_table(ppc_list, obs_data, mn),
    error = function(e) { message("    qpf_table ERROR: ", e$message); NULL }
  )
  qpf_resp_rows[[mn]] <- tryCatch(
    compute_qpf_table(ppc_list, obs_data, mn, by_response = TRUE),
    error = function(e) { message("    qpf_by_response ERROR: ", e$message); NULL }
  )
  rm(ppc_list)   # free memory before next model
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

# Per-model AD FDR summary
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

# B. Choice proportions
if (nrow(choice_df) > 0L) {
  save_ggplot_png(plot_ppc_choice(choice_df, x_var = "cue_size"),
                  file.path(PPC_EVAL_DIR, "ppc_choice_cue.png"))
  save_ggplot_png(plot_ppc_choice(choice_df, x_var = "search_difficulty"),
                  file.path(PPC_EVAL_DIR, "ppc_choice_difficulty.png"))
}

# C. Marginal QPF
if (nrow(qpf_df) > 0L) {
  save_ggplot_png(plot_ppc_qpf(qpf_df, x_var = "cue_size"),
                  file.path(PPC_EVAL_DIR, "ppc_qpf_cue.png"),
                  width = 12, height = 10)
  save_ggplot_png(plot_ppc_qpf(qpf_df, x_var = "search_difficulty"),
                  file.path(PPC_EVAL_DIR, "ppc_qpf_difficulty.png"),
                  width = 12, height = 10)
}

# D. QPF by response type
if (!is.null(qpf_resp_df) && nrow(qpf_resp_df) > 0L) {
  save_ggplot_png(plot_ppc_qpf_by_response(qpf_resp_df, x_var = "cue_size"),
                  file.path(PPC_EVAL_DIR, "ppc_qpf_resp_cue.png"),
                  width = 14, height = 10)
  save_ggplot_png(plot_ppc_qpf_by_response(qpf_resp_df, x_var = "search_difficulty"),
                  file.path(PPC_EVAL_DIR, "ppc_qpf_resp_difficulty.png"),
                  width = 14, height = 10)
}

# E. Defective CDFs (requires both qpf_resp_df and choice_df)
if (!is.null(qpf_resp_df) && nrow(qpf_resp_df) > 0L && nrow(choice_df) > 0L) {
  save_ggplot_png(plot_ppc_cdf(qpf_resp_df, choice_df, x_facet = "cue_size"),
                  file.path(PPC_EVAL_DIR, "ppc_cdf_cue.png"),
                  width = 14, height = 8)
  save_ggplot_png(plot_ppc_cdf(qpf_resp_df, choice_df, x_facet = "search_difficulty"),
                  file.path(PPC_EVAL_DIR, "ppc_cdf_difficulty.png"),
                  width = 14, height = 8)
}

message("===== ppc.R complete; outputs in ", PPC_EVAL_DIR, " =====")
