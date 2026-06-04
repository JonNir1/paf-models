#' =============================================================================
#' PPC Eval Helpers (step 4)
#'
#' Computes distribution-fit statistics (KS, Anderson-Darling), choice-proportion
#' tables, and quantile probability function (QPF) tables from a list of posterior
#' predictive datasets. All computations are data-level (not parameter-level), so
#' they are valid for all models including models 4 & 5 with structurally
#' unidentifiable StimulusAtLoc x SearchDifficulty parameters.
#'
#' Exports:
#'   compute_dist_stats()         -- per-subject KS + AD + BH FDR
#'   compute_choice_proportions() -- predicted vs obs saccade target fractions
#'   compute_qpf_table()          -- predicted vs obs RT quantile functions
#'   plot_ppc_dist_stats()        -- violin/jitter of KS D and AD statistic
#'   plot_ppc_choice()            -- predicted ribbon + observed points (choice)
#'   plot_ppc_qpf()               -- QPF overlay (predicted ribbon + observed points)
#'
#' Dependencies: dplyr, ggplot2 (plots only), ADGofTest (compute_dist_stats only).
#' Source chain: ppc.R -> eval_config.R -> config.R, utils.R
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))


# =============================================================================
# Internal helpers
# =============================================================================

# Extract the stimulus type at the response location for each row.
# S is a comma-separated string (e.g. "T,E,E,D"); R is the 1-based location.
# Returns character vector: "T" = target, "D" = difficult distractor, "E" = easy.
.response_type <- function(data) {
  clean_S <- gsub(",", "", as.character(data$S))
  loc_idx <- as.integer(data$R)
  substr(clean_S, loc_idx, loc_idx)
}


# =============================================================================
# compute_dist_stats()
# =============================================================================

#' Per-subject distribution fit statistics: KS + Anderson-Darling + BH FDR.
#'
#' Pools all T simulated RT vectors per subject into one predictive sample,
#' then runs ks.test() and ADGofTest::ad.test() against observed RTs.
#' FDR (Benjamini-Hochberg) is applied to AD p-values across subjects within
#' this model (not across models). KS is retained as secondary diagnostic.
#'
#' @param ppc_list   List of T simulated data frames (from fit_ppc_cloud.R).
#' @param obs_data   Observed data frame; must have columns subjects, rt.
#' @param model_name Character; model identifier added to the output.
#' @return data.frame with columns: model, subject, ks_d, ks_p, ad, ad_p,
#'   ad_p_fdr, fdr_pass.
compute_dist_stats <- function(ppc_list, obs_data, model_name) {
  if (!requireNamespace("ADGofTest", quietly = TRUE)) {
    stop("Package 'ADGofTest' is required for compute_dist_stats(). ",
         "Install with: install.packages('ADGofTest')")
  }

  subjects <- unique(obs_data$subjects)
  rows <- lapply(subjects, function(subj) {
    obs_rt  <- obs_data$rt[obs_data$subjects == subj]
    pred_rt <- unlist(lapply(ppc_list, function(d) d$rt[d$subjects == subj]))
    if (length(obs_rt) < 2L || length(pred_rt) < 2L) {
      return(data.frame(model = model_name, subject = subj,
                        ks_d = NA_real_, ks_p = NA_real_,
                        ad   = NA_real_, ad_p = NA_real_,
                        stringsAsFactors = FALSE))
    }
    ks_res <- ks.test(obs_rt, pred_rt)
    ad_res <- ADGofTest::ad.test(obs_rt, pred_rt)
    data.frame(model   = model_name,
               subject = subj,
               ks_d    = unname(ks_res$statistic),
               ks_p    = ks_res$p.value,
               ad      = unname(ad_res$statistic),
               ad_p    = ad_res$p.value,
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)

  # BH FDR correction on AD p-values within this model
  out$ad_p_fdr <- p.adjust(out$ad_p, method = "BH")
  out$fdr_pass <- !is.na(out$ad_p_fdr) & out$ad_p_fdr >= PPC_AD_ALPHA
  out
}


# =============================================================================
# compute_choice_proportions()
# =============================================================================

#' Predicted vs observed saccade target proportions per condition.
#'
#' Response types: "T" (target), "D" (difficult distractor), "E" (easy distractor),
#' classified from the stimulus string S at the response location R.
#'
#' For each condition cell (experiment x cue_size x search_difficulty), computes
#' the proportion of saccades to each response type. Prediction is summarised as
#' median + 90% CI across T draws.
#'
#' @param ppc_list   List of T simulated data frames.
#' @param obs_data   Observed data frame; must have S, R, cue_size,
#'                   search_difficulty, experiment.
#' @param model_name Character model identifier.
#' @return Long-format data.frame with columns: model, experiment, cue_size,
#'   search_difficulty, response_type, obs, pred_median, pred_ci_lo, pred_ci_hi.
compute_choice_proportions <- function(ppc_list, obs_data, model_name) {
  resp_types <- c("T", "D", "E")

  obs_data$response_type <- .response_type(obs_data)
  conditions <- unique(obs_data[, c("experiment", "cue_size", "search_difficulty"),
                                drop = FALSE])

  rows <- lapply(seq_len(nrow(conditions)), function(r) {
    cond <- conditions[r, , drop = FALSE]
    obs_sel <- obs_data$experiment        == cond$experiment &
               obs_data$cue_size          == cond$cue_size &
               obs_data$search_difficulty == cond$search_difficulty

    lapply(resp_types, function(rt) {
      obs_prop <- mean(obs_data$response_type[obs_sel] == rt)

      draw_vals <- vapply(ppc_list, function(d) {
        sim_sel <- d$experiment        == cond$experiment &
                   d$cue_size          == cond$cue_size &
                   d$search_difficulty == cond$search_difficulty
        if (sum(sim_sel) == 0L) return(NA_real_)
        d$response_type <- .response_type(d)
        mean(d$response_type[sim_sel] == rt)
      }, numeric(1L))

      data.frame(
        model             = model_name,
        experiment        = cond$experiment,
        cue_size          = cond$cue_size,
        search_difficulty = cond$search_difficulty,
        response_type     = rt,
        obs               = obs_prop,
        pred_median       = median(draw_vals, na.rm = TRUE),
        pred_ci_lo        = quantile(draw_vals, 0.05, na.rm = TRUE),
        pred_ci_hi        = quantile(draw_vals, 0.95, na.rm = TRUE),
        stringsAsFactors  = FALSE
      )
    })
  })

  out <- do.call(rbind, unlist(rows, recursive = FALSE))
  rownames(out) <- NULL
  out
}


# =============================================================================
# compute_qpf_table()
# =============================================================================

#' Quantile probability function table: predicted vs observed RT quantiles.
#'
#' QPF quantiles: 10th, 25th, 50th, 75th, 90th percentile of RT per condition.
#' Predictions are summarised as median + 90% CI across the T draws.
#'
#' @param ppc_list   List of T simulated data frames.
#' @param obs_data   Observed data frame; must have rt, cue_size,
#'                   search_difficulty, experiment.
#' @param model_name Character model identifier.
#' @return Long-format data.frame with columns: model, experiment, cue_size,
#'   search_difficulty, quantile, obs, pred_median, pred_ci_lo, pred_ci_hi.
compute_qpf_table <- function(ppc_list, obs_data, model_name) {
  probs <- c(0.10, 0.25, 0.50, 0.75, 0.90)

  conditions <- unique(obs_data[, c("experiment", "cue_size", "search_difficulty"),
                                drop = FALSE])

  rows <- lapply(seq_len(nrow(conditions)), function(r) {
    cond    <- conditions[r, , drop = FALSE]
    obs_sel <- obs_data$experiment        == cond$experiment &
               obs_data$cue_size          == cond$cue_size &
               obs_data$search_difficulty == cond$search_difficulty

    lapply(probs, function(p) {
      obs_q <- quantile(obs_data$rt[obs_sel], p)

      draw_vals <- vapply(ppc_list, function(d) {
        sim_sel <- d$experiment        == cond$experiment &
                   d$cue_size          == cond$cue_size &
                   d$search_difficulty == cond$search_difficulty
        if (sum(sim_sel) < 2L) return(NA_real_)
        quantile(d$rt[sim_sel], p)
      }, numeric(1L))

      data.frame(
        model             = model_name,
        experiment        = cond$experiment,
        cue_size          = cond$cue_size,
        search_difficulty = cond$search_difficulty,
        quantile          = p,
        obs               = obs_q,
        pred_median       = median(draw_vals, na.rm = TRUE),
        pred_ci_lo        = quantile(draw_vals, 0.05, na.rm = TRUE),
        pred_ci_hi        = quantile(draw_vals, 0.95, na.rm = TRUE),
        stringsAsFactors  = FALSE
      )
    })
  })

  out <- do.call(rbind, unlist(rows, recursive = FALSE))
  rownames(out) <- NULL
  out
}


# =============================================================================
# Plot builders (require ggplot2; not called from CI test suite)
# =============================================================================

#' Violin + jitter of KS D and AD statistic per model, coloured by fdr_pass.
#'
#' @param stats_df Output of compute_dist_stats() (possibly rbind across models).
#' @return A ggplot.
plot_ppc_dist_stats <- function(stats_df) {
  library(ggplot2)
  stats_df$fdr_label <- ifelse(is.na(stats_df$fdr_pass), NA_character_,
                               ifelse(stats_df$fdr_pass, "pass", "fail"))
  stats_df$fdr_label <- factor(stats_df$fdr_label, levels = c("pass", "fail"))
  long <- rbind(
    data.frame(model = stats_df$model, fdr_label = stats_df$fdr_label,
               metric = "KS D",         value = stats_df$ks_d),
    data.frame(model = stats_df$model, fdr_label = stats_df$fdr_label,
               metric = "AD statistic", value = stats_df$ad)
  )
  ggplot(long, aes(model, value, colour = fdr_label)) +
    geom_violin(fill = NA, colour = "grey60", width = 0.8) +
    geom_jitter(width = 0.15, size = 1.5, alpha = 0.7) +
    facet_wrap(~metric, scales = "free_y") +
    scale_colour_manual(values = c(pass = "#2c7fb8", fail = "#d7301f"),
                        na.value = "grey60", name = "FDR pass",
                        na.translate = FALSE) +
    labs(x = NULL, y = NULL,
         title = "PPC distribution fit per subject (step 4)",
         subtitle = paste0("AD FDR threshold = ", PPC_AD_ALPHA,
                           " (BH within model); KS shown for reference")) +
    theme_bw(base_size = 12) +
    theme(axis.text.x = element_text(angle = 20, hjust = 1))
}


#' Predicted (ribbon + line) vs observed (points) saccade proportions.
#'
#' @param choice_df Output of compute_choice_proportions().
#' @param x_var     Column to use as x-axis: "cue_size" or "search_difficulty".
#' @return A ggplot, faceted by model.
plot_ppc_choice <- function(choice_df, x_var = "cue_size") {
  library(ggplot2)
  stopifnot(x_var %in% c("cue_size", "search_difficulty"))
  resp_colors <- c(T = "#2c7fb8", D = "#d7301f", E = "#f0a500")
  choice_df$x_val <- factor(choice_df[[x_var]])
  ggplot(choice_df, aes(x_val, group = response_type)) +
    geom_ribbon(aes(ymin = pred_ci_lo, ymax = pred_ci_hi, fill = response_type),
                alpha = 0.25) +
    geom_line(aes(y = pred_median, colour = response_type), linewidth = 0.8) +
    geom_point(aes(y = obs, colour = response_type), size = 2) +
    facet_wrap(~model) +
    scale_colour_manual(values = resp_colors, name = "response type",
                        labels = c(T = "target", D = "difficult", E = "easy")) +
    scale_fill_manual(values = resp_colors, name = "response type",
                      labels = c(T = "target", D = "difficult", E = "easy")) +
    labs(x = x_var, y = "proportion",
         title = sprintf("PPC choice proportions by %s (step 4)", x_var),
         subtitle = "Line + ribbon = posterior predictive median + 90% CI; points = observed") +
    theme_bw(base_size = 12) +
    theme(legend.position = "bottom")
}


#' QPF overlay: predicted (ribbon + line) vs observed (points) RT quantiles.
#'
#' @param qpf_df  Output of compute_qpf_table().
#' @param x_var   Column for x-axis: "cue_size" or "search_difficulty".
#' @return A ggplot, faceted by model x quantile.
plot_ppc_qpf <- function(qpf_df, x_var = "cue_size") {
  library(ggplot2)
  stopifnot(x_var %in% c("cue_size", "search_difficulty"))
  qpf_df$x_val   <- factor(qpf_df[[x_var]])
  qpf_df$q_label <- sprintf("q%02.0f", qpf_df$quantile * 100)
  ggplot(qpf_df, aes(x_val, group = 1L)) +
    geom_ribbon(aes(ymin = pred_ci_lo, ymax = pred_ci_hi),
                fill = "#2c7fb8", alpha = 0.25) +
    geom_line(aes(y = pred_median), colour = "#2c7fb8", linewidth = 0.8) +
    geom_point(aes(y = obs), colour = "#d7301f", size = 2) +
    facet_grid(q_label ~ model) +
    labs(x = x_var, y = "RT (s)",
         title = sprintf("QPF: predicted vs observed RT quantiles by %s (step 4)", x_var),
         subtitle = "Blue line + ribbon = posterior predictive median + 90% CI; red = observed") +
    theme_bw(base_size = 12) +
    theme(axis.text.x = element_text(angle = 20, hjust = 1))
}
