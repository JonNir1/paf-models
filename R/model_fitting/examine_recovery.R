#' =============================================================================
#' Parameter Recovery Analysis (step 2.5)
#'
#' Loads the 12 recovery fits (4 models x 3 sims) and their corresponding
#' true subject parameters, then produces:
#'
#'   A. Population-level table (Strickland et al. 2026, Table S2 style):
#'      true mu vs. mean estimated mu, one row per parameter.
#'
#'   B. Subject-level scatter (Strickland et al. 2026, Figure S2 style):
#'      estimated alpha_i vs. true alpha_i using EMC2::recovery().
#'      Reports RMSE and Pearson r per model.
#'
#'   C. Posterior z-scores and contraction (Schad, Betancourt & Vasishth 2021,
#'      Psychological Methods, Figure 15 style):
#'      z = (mu_estimated - mu_true) / SD_posterior
#'      contraction = 1 - var(posterior) / var(prior)
#'
#' Outputs saved to Results/parameter_recovery/.
#'
#' Run from the repo root after downloading all 12 .rds pairs from S3:
#'   source("R/model_fitting/examine_recovery.R")
#' =============================================================================

source("R/config.R")
source("R/model_fitting/helpers/recovery.R")
library(EMC2)
library(dplyr)

RECOVERY_OUT_DIR <- file.path(RESULTS_DIR, "parameter_recovery")
if (!dir.exists(RECOVERY_OUT_DIR)) dir.create(RECOVERY_OUT_DIR, recursive = TRUE)

MODEL_NAMES <- c("model1", "model2", "model4", "model5")
N_SIMS      <- 3L


# =============================================================================
#  Helper: load the most recent recovery .rds pair for a given model + sim
# =============================================================================

.load_recovery_pair <- function(model_name, sim_index, dir = MODELS_RECOVERY_DIR) {
  pattern <- sprintf("^[0-9]{6}_%s_recovery_sim%d\\.rds$", model_name, sim_index)
  files   <- list.files(dir, pattern = pattern, full.names = TRUE)
  if (length(files) == 0L)
    stop(sprintf("No recovery .rds found for %s sim%d in %s", model_name, sim_index, dir))
  # Take the most recent (latest date prefix)
  rds_path <- sort(files)[length(files)]

  alpha_pattern <- sprintf("^[0-9]{6}_%s_recovery_sim%d_true_alpha\\.rds$", model_name, sim_index)
  alpha_files   <- list.files(dir, pattern = alpha_pattern, full.names = TRUE)
  if (length(alpha_files) == 0L)
    stop(sprintf("No true_alpha .rds found for %s sim%d in %s", model_name, sim_index, dir))
  alpha_path <- sort(alpha_files)[length(alpha_files)]

  list(
    model      = readRDS(rds_path),
    true_alpha = readRDS(alpha_path),
    model_name = model_name,
    sim_index  = sim_index,
    rds_path   = rds_path
  )
}


# =============================================================================
#  Load all 12 pairs
# =============================================================================

message("Loading recovery fits...")
all_pairs <- list()
for (mn in MODEL_NAMES) {
  for (si in seq_len(N_SIMS)) {
    key <- sprintf("%s_sim%d", mn, si)
    message(sprintf("  %s", key))
    all_pairs[[key]] <- tryCatch(
      .load_recovery_pair(mn, si),
      error = function(e) { message("  MISSING: ", e$message); NULL }
    )
  }
}

available <- Filter(Negate(is.null), all_pairs)
message(sprintf("Loaded %d / %d recovery pairs.", length(available), length(MODEL_NAMES) * N_SIMS))


# =============================================================================
#  A. Population-level table (Strickland Table S2 style)
# =============================================================================

message("\n--- A. Population-level recovery table ---")

pop_rows <- list()
for (pair in available) {
  mn  <- pair$model_name
  si  <- pair$sim_index
  fit <- pair$model

  # True mu: extract from the paired true_alpha's column means
  # (the true group mu was used to generate true_alpha; recover it via get_pars on extended model)
  # We re-extract from the fitted recovery model's posterior
  mu_samples <- get_pars(fit, selection = "mu", stage = "sample",
                         map = FALSE, return_mcmc = TRUE)
  mu_mat     <- do.call(rbind, mu_samples)
  mu_est     <- colMeans(mu_mat)
  mu_sd      <- apply(mu_mat, 2, sd)

  # True mu: we need the group_params that were used -- stored implicitly in the
  # true_alpha matrix column means are subject-level, not group-level.
  # Best available: the posterior mean from the EXTENDED model (ground truth).
  # Load the corresponding extended model to get its group params.
  ext_pattern <- sprintf("^[0-9]{6}_%s_extended\\.rds$", mn)
  ext_files   <- list.files(MODELS_EXTEND_DIR, pattern = ext_pattern, full.names = TRUE)
  if (length(ext_files) == 0L) {
    message(sprintf("  WARNING: no extended .rds for %s; skipping true mu.", mn))
    next
  }
  ext_model  <- readRDS(sort(ext_files)[length(ext_files)])
  true_group <- extract_group_params(ext_model)
  mu_true    <- true_group$mu

  # Align parameter names
  common_pars <- intersect(names(mu_true), names(mu_est))
  for (p in common_pars) {
    pop_rows[[length(pop_rows) + 1L]] <- data.frame(
      model     = mn,
      sim       = si,
      parameter = p,
      mu_true   = mu_true[[p]],
      mu_est    = mu_est[[p]],
      mu_sd     = mu_sd[[p]],
      stringsAsFactors = FALSE
    )
  }
}

pop_table <- do.call(rbind, pop_rows)

# Summary: average across sims per model x parameter
pop_summary <- pop_table %>%
  group_by(model, parameter) %>%
  summarise(
    mu_true     = mean(mu_true),
    mu_est_mean = mean(mu_est),
    mu_est_sd   = mean(mu_sd),
    .groups     = "drop"
  )

write.csv(pop_table,   file.path(RECOVERY_OUT_DIR, "recovery_population_raw.csv"),   row.names = FALSE)
write.csv(pop_summary, file.path(RECOVERY_OUT_DIR, "recovery_population_table.csv"), row.names = FALSE)
message("  Saved: recovery_population_table.csv")
print(pop_summary, n = Inf)


# =============================================================================
#  B. Subject-level scatter via EMC2::recovery()
# =============================================================================

message("\n--- B. Subject-level recovery scatter (EMC2::recovery) ---")

for (mn in MODEL_NAMES) {
  model_pairs <- Filter(function(p) p$model_name == mn, available)
  if (length(model_pairs) == 0L) next

  out_file <- file.path(RECOVERY_OUT_DIR, sprintf("recovery_subject_scatter_%s.pdf", mn))
  pdf(out_file, width = 10, height = 8)

  for (pair in model_pairs) {
    tryCatch({
      # recovery() at alpha level: estimated vs. true subject params
      recovery(pair$model,
               true_pars = pair$true_alpha,
               selection = "alpha",
               stat      = "rmse",
               main      = sprintf("%s sim%d -- subject-level (alpha)", mn, pair$sim_index))
    }, error = function(e) {
      message(sprintf("  recovery() alpha failed for %s sim%d: %s", mn, pair$sim_index, e$message))
    })
  }

  dev.off()
  message(sprintf("  Saved: %s", out_file))
}


# =============================================================================
#  C. Posterior z-scores and contraction (Schad, Betancourt & Vasishth 2021)
# =============================================================================

message("\n--- C. Posterior z-scores and contraction (Schad et al. 2021) ---")

# Prior variance for each parameter: read from config.R prior SDs
# config.R defines *_SD constants. Collect them to compute var(prior).
.get_prior_sd <- function(par_name) {
  # Map EMC2 parameter names back to config.R SD constants.
  # This is a best-effort lookup; unmapped parameters get NA.
  sd_map <- c(
    v                          = V_BASELINE_SD,
    v_PrevTargetAtLocTRUE      = V_PREVTAR_TRUE_SD,
    v_CueAtLocSMALL            = V_CUE_S_SD,
    v_CueAtLocMEDIUM           = V_CUE_M_SD,
    v_CueAtLocLARGE            = V_CUE_L_SD,
    v_StimulusAtLocD           = V_STIM_D_SD,
    v_StimulusAtLocE           = V_STIM_E_SD,
    v_StimulusAtLocD_SearchDifficultyMIXED    = V_STIM_D_SEARCH_MIX_SD,
    v_StimulusAtLocD_SearchDifficultyDIFFICULT = V_STIM_D_SEARCH_DIF_SD,
    v_StimulusAtLocE_SearchDifficultyMIXED    = V_STIM_E_SEARCH_MIX_SD,
    v_StimulusAtLocE_SearchDifficultyDIFFICULT = V_STIM_E_SEARCH_DIF_SD,
    sv_StimulusAtLocD          = SV_STIM_D_SD,
    sv_StimulusAtLocE          = SV_STIM_E_SD,
    B                          = B_BASELINE_SD,
    B_SearchDifficultyMIXED    = B_SEARCH_MIX_SD,
    B_SearchDifficultyDIFFICULT = B_SEARCH_DIF_SD,
    A                          = A_SD,
    t0                         = T0_SD
  )
  if (par_name %in% names(sd_map)) sd_map[[par_name]] else NA_real_
}

zscore_rows <- list()
for (pair in available) {
  mn  <- pair$model_name
  si  <- pair$sim_index
  fit <- pair$model

  # Posterior samples of mu
  mu_samples <- get_pars(fit, selection = "mu", stage = "sample",
                         map = FALSE, return_mcmc = TRUE)
  mu_mat <- do.call(rbind, mu_samples)
  mu_est <- colMeans(mu_mat)
  mu_sd  <- apply(mu_mat, 2, sd)

  # True mu from extended model
  ext_pattern <- sprintf("^[0-9]{6}_%s_extended\\.rds$", mn)
  ext_files   <- list.files(MODELS_EXTEND_DIR, pattern = ext_pattern, full.names = TRUE)
  if (length(ext_files) == 0L) next
  ext_model  <- readRDS(sort(ext_files)[length(ext_files)])
  true_group <- extract_group_params(ext_model)
  mu_true    <- true_group$mu

  common_pars <- intersect(names(mu_true), names(mu_est))
  for (p in common_pars) {
    prior_sd   <- .get_prior_sd(p)
    post_var   <- mu_sd[[p]]^2
    prior_var  <- if (!is.na(prior_sd)) prior_sd^2 else NA_real_
    contraction <- if (!is.na(prior_var) && prior_var > 0) 1 - post_var / prior_var else NA_real_

    zscore_rows[[length(zscore_rows) + 1L]] <- data.frame(
      model       = mn,
      sim         = si,
      parameter   = p,
      mu_true     = mu_true[[p]],
      mu_est      = mu_est[[p]],
      mu_sd       = mu_sd[[p]],
      z_score     = (mu_est[[p]] - mu_true[[p]]) / mu_sd[[p]],
      contraction = contraction,
      stringsAsFactors = FALSE
    )
  }
}

zscore_table <- do.call(rbind, zscore_rows)
write.csv(zscore_table, file.path(RECOVERY_OUT_DIR, "recovery_zscores_contraction.csv"),
          row.names = FALSE)
message("  Saved: recovery_zscores_contraction.csv")

# Plot: z-score vs. contraction per model (Schad et al. Figure 15 style)
for (mn in MODEL_NAMES) {
  df <- zscore_table[zscore_table$model == mn, ]
  if (nrow(df) == 0L) next

  out_file <- file.path(RECOVERY_OUT_DIR, sprintf("recovery_zscore_contraction_%s.pdf", mn))
  pdf(out_file, width = 6, height = 5)
  plot(df$contraction, df$z_score,
       xlab = "Posterior contraction (1 - var_post/var_prior)",
       ylab = "Posterior z-score ((est - true) / SD_post)",
       main = sprintf("%s -- z-score vs contraction (Schad et al. 2021)", mn),
       pch  = 19, col = "steelblue",
       xlim = c(0, 1), ylim = c(-3, 3))
  abline(h = c(-2, 0, 2), lty = c(2, 1, 2), col = c("red", "grey", "red"))
  abline(v = 0.5, lty = 2, col = "orange")
  text(df$contraction, df$z_score, labels = df$parameter, cex = 0.5, pos = 3)
  dev.off()
  message(sprintf("  Saved: %s", out_file))
}

message("\n===== examine_recovery.R complete =====")
message(sprintf("Outputs in: %s", RECOVERY_OUT_DIR))
