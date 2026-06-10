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
#'                                   (marginal, or stratified by response type)
#'   plot_ppc_dist_stats()        -- violin/jitter of KS D and AD statistic
#'   plot_ppc_choice()            -- predicted ribbon + observed points (choice)
#'   plot_ppc_qpf()               -- marginal QPF overlay
#'   plot_ppc_qpf_by_response()   -- QPF stratified by T/D/E response type
#'   plot_ppc_cdf()               -- defective CDF reconstructed from QPF + choice
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

# Shared model colour palette used by all multi-model plots.
.model_colors <- c(model1 = "#2c7fb8", model2 = "#31a354",
                   model4 = "#d95f02", model5 = "#7570b3")


# =============================================================================
# compute_dist_stats()
# =============================================================================

#' Per-subject distribution fit statistics: two-sample KS + BH FDR.
#'
#' Pools all T simulated RT vectors per subject into one predictive sample,
#' then runs ks.test() (base R, two-sample) against observed RTs.
#' FDR (Benjamini-Hochberg) is applied to KS p-values across subjects within
#' this model (not across models).
#'
#' Note: the KS test has lower power than Anderson-Darling for tail differences,
#' but is sufficient here: (a) the pooled predicted sample is extremely large
#' (T x N_obs per subject), giving very high power; (b) QPF plots directly
#' surface tail misfit more informatively than any formal tail-sensitive test.
#'
#' @param ppc_list   List of T simulated data frames (from fit_ppc_cloud.R).
#' @param obs_data   Observed data frame; must have columns subjects, rt.
#' @param model_name Character; model identifier added to the output.
#' @return data.frame with columns: model, subject, ks_d, ks_p,
#'   ks_p_fdr, fdr_pass.
compute_dist_stats <- function(ppc_list, obs_data, model_name) {
  subjects <- unique(obs_data$subjects)
  rows <- lapply(subjects, function(subj) {
    obs_rt  <- obs_data$rt[obs_data$subjects == subj]
    pred_rt <- unlist(lapply(ppc_list, function(d) d$rt[d$subjects == subj]))
    if (length(obs_rt) < 2L || length(pred_rt) < 2L) {
      return(data.frame(model = model_name, subject = subj,
                        ks_d = NA_real_, ks_p = NA_real_,
                        stringsAsFactors = FALSE))
    }
    ks_res <- ks.test(obs_rt, pred_rt)
    data.frame(model   = model_name,
               subject = subj,
               ks_d    = unname(ks_res$statistic),
               ks_p    = ks_res$p.value,
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)

  # BH FDR correction on KS p-values within this model
  out$ks_p_fdr <- p.adjust(out$ks_p, method = "BH")
  out$fdr_pass <- !is.na(out$ks_p_fdr) & out$ks_p_fdr >= PPC_AD_ALPHA
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
#' @param ppc_list    List of T simulated data frames.
#' @param obs_data    Observed data frame; must have rt, cue_size,
#'                    search_difficulty, experiment (and S, R when by_response=TRUE).
#' @param model_name  Character model identifier.
#' @param by_response Logical (default FALSE). When TRUE, stratify by response
#'                    type (T/D/E); adds a response_type column to the output.
#'                    Sparse cells (fewer than min_n observed trials of that type)
#'                    are silently skipped.
#' @param min_n       Minimum observed trials required per (condition x response_type)
#'                    cell when by_response=TRUE (default 10).
#' @return Long-format data.frame. Columns: model, experiment, cue_size,
#'   search_difficulty, quantile, obs, pred_median, pred_ci_lo, pred_ci_hi.
#'   Plus response_type when by_response=TRUE.
compute_qpf_table <- function(ppc_list, obs_data, model_name,
                               by_response = FALSE, min_n = 10L) {
  probs <- c(0.10, 0.25, 0.50, 0.75, 0.90)

  # Pre-annotate with response type once (avoids recomputing per draw per cell)
  if (by_response) {
    obs_data$response_type <- .response_type(obs_data)
    ppc_list <- lapply(ppc_list, function(d) {
      d$response_type <- .response_type(d)
      d
    })
    rt_loop <- c("T", "D", "E")
  } else {
    rt_loop <- list(NULL)   # single NULL sentinel: run once without RT filter
  }

  conditions <- unique(obs_data[, c("experiment", "cue_size", "search_difficulty"),
                                drop = FALSE])

  rows <- lapply(seq_len(nrow(conditions)), function(r) {
    cond     <- conditions[r, , drop = FALSE]
    cond_sel <- obs_data$experiment        == cond$experiment &
                obs_data$cue_size          == cond$cue_size &
                obs_data$search_difficulty == cond$search_difficulty

    rt_results <- lapply(rt_loop, function(rt) {
      obs_sel <- if (is.null(rt)) cond_sel else cond_sel & obs_data$response_type == rt

      # Skip sparse cells
      n_req <- if (is.null(rt)) 2L else min_n
      if (sum(obs_sel) < n_req) return(NULL)

      prob_results <- lapply(probs, function(p) {
        obs_q <- quantile(obs_data$rt[obs_sel], p)

        draw_vals <- vapply(ppc_list, function(d) {
          sim_sel <- d$experiment        == cond$experiment &
                     d$cue_size          == cond$cue_size &
                     d$search_difficulty == cond$search_difficulty
          if (!is.null(rt)) sim_sel <- sim_sel & d$response_type == rt
          if (sum(sim_sel) < 2L) return(NA_real_)
          quantile(d$rt[sim_sel], p)
        }, numeric(1L))

        row <- data.frame(
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
        if (!is.null(rt)) row$response_type <- rt
        row
      })
      prob_results   # list of 5 data.frames
    })
    unlist(rt_results, recursive = FALSE)   # flatten rt x probs into list of DFs
  })

  all_rows <- Filter(Negate(is.null), unlist(rows, recursive = FALSE))
  if (length(all_rows) == 0L) return(data.frame())
  out <- do.call(rbind, all_rows)
  rownames(out) <- NULL
  out
}


# =============================================================================
# Plot builders (require ggplot2; not called from CI test suite)
# =============================================================================

#' Violin + jitter of KS D statistic per model, coloured by fdr_pass.
#'
#' @param stats_df Output of compute_dist_stats() (possibly rbind across models).
#' @return A ggplot.
plot_ppc_dist_stats <- function(stats_df) {
  library(ggplot2)
  stats_df$fdr_label <- ifelse(is.na(stats_df$fdr_pass), NA_character_,
                               ifelse(stats_df$fdr_pass, "pass", "fail"))
  stats_df$fdr_label <- factor(stats_df$fdr_label, levels = c("pass", "fail"))
  ggplot(stats_df, aes(model, ks_d, colour = fdr_label)) +
    geom_violin(fill = NA, colour = "grey60", width = 0.8) +
    geom_jitter(width = 0.15, size = 1.5, alpha = 0.7) +
    scale_colour_manual(values = c(pass = "#2c7fb8", fail = "#d7301f"),
                        na.value = "grey60", name = "FDR pass",
                        na.translate = FALSE) +
    labs(x = NULL, y = "KS D statistic",
         title = "PPC distribution fit per subject (step 4)",
         subtitle = paste0("KS FDR threshold = ", PPC_AD_ALPHA,
                           " (Benjamini-Hochberg within model)")) +
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


#' Marginal QPF overlay: predicted (ribbon + line) vs observed (points) RT quantiles.
#'
#' @param qpf_df  Output of compute_qpf_table() with by_response=FALSE (default).
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


#' QPF stratified by response type: predicted vs observed RT quantiles.
#'
#' Mirrors Strickland et al. (2026) paper 2 Fig. 14-15 style: quantile per
#' response type (target / difficult distractor / easy distractor) by condition.
#' Each model is shown in a different colour, overlaid on the same axes.
#'
#' @param qpf_resp_df  Output of compute_qpf_table(by_response = TRUE).
#' @param x_var        Column for x-axis: "cue_size" or "search_difficulty".
#' @return A ggplot, faceted by quantile x response_type, coloured by model.
plot_ppc_qpf_by_response <- function(qpf_resp_df, x_var = "cue_size") {
  library(ggplot2)
  stopifnot("response_type" %in% names(qpf_resp_df),
            x_var %in% c("cue_size", "search_difficulty"))

  resp_labels <- c(T = "target", D = "difficult distractor", E = "easy distractor")
  qpf_resp_df$x_val     <- factor(qpf_resp_df[[x_var]])
  qpf_resp_df$q_label   <- sprintf("q%02.0f", qpf_resp_df$quantile * 100)
  qpf_resp_df$resp_label <- factor(resp_labels[qpf_resp_df$response_type],
                                    levels = resp_labels)

  ggplot(qpf_resp_df, aes(x_val, colour = model, fill = model, group = model)) +
    geom_ribbon(aes(ymin = pred_ci_lo, ymax = pred_ci_hi),
                alpha = 0.15, colour = NA) +
    geom_line(aes(y = pred_median), linewidth = 0.7) +
    # Observed: open white circles with coloured border (per Strickland et al.)
    geom_point(aes(y = obs), shape = 21, fill = "white", stroke = 1.2, size = 2) +
    facet_grid(q_label ~ resp_label) +
    scale_colour_manual(values = .model_colors) +
    scale_fill_manual(values = .model_colors) +
    labs(x = x_var, y = "RT (s)",
         title = sprintf("QPF by response type: predicted vs observed by %s (step 4)", x_var),
         subtitle = paste0("Coloured line + ribbon = posterior predictive median + 90% CI; ",
                           "open circle = observed")) +
    theme_bw(base_size = 12) +
    theme(axis.text.x = element_text(angle = 20, hjust = 1),
          legend.position = "bottom")
}


#' Defective CDF (step 4): reconstructed from QPF-by-response + choice proportions.
#'
#' Implements the canonical EMC2 PPC visualization (Stevenson et al. 2026, paper 1
#' Figs 6/9): p(RT <= t, R = r) vs t per condition x response type.
#'
#' The CDF is _reconstructed_ (not recomputed from raw draws): at each quantile
#' level p, x = RT quantile and y = p * choice_proportion, because
#'   p(RT <= q_p, R = r) = P(R = r) * p(RT <= q_p | R = r) = CP_r * p.
#'
#' Ribbon reflects 90% CI on the choice-proportion axis (dominant uncertainty
#' source). All 4 models overlaid; observed shown in black.
#'
#' @param qpf_resp_df  Output of compute_qpf_table(by_response = TRUE).
#' @param choice_df    Output of compute_choice_proportions().
#' @param x_facet      Column to facet columns by: "cue_size" or
#'                     "search_difficulty".
#' @return A ggplot, faceted by response_type (rows) x x_facet (columns).
plot_ppc_cdf <- function(qpf_resp_df, choice_df, x_facet = "cue_size") {
  library(ggplot2)
  stopifnot("response_type" %in% names(qpf_resp_df),
            x_facet %in% c("cue_size", "search_difficulty"))

  # ---- Merge QPF with choice proportions ----
  merge_keys <- c("model", "experiment", "cue_size", "search_difficulty", "response_type")
  cp_sub <- choice_df[, c(merge_keys, "obs", "pred_median", "pred_ci_lo", "pred_ci_hi"),
                       drop = FALSE]
  names(cp_sub)[names(cp_sub) == "obs"]        <- "cp_obs"
  names(cp_sub)[names(cp_sub) == "pred_median"] <- "cp_pred_med"
  names(cp_sub)[names(cp_sub) == "pred_ci_lo"]  <- "cp_pred_lo"
  names(cp_sub)[names(cp_sub) == "pred_ci_hi"]  <- "cp_pred_hi"

  cdf_df <- merge(qpf_resp_df, cp_sub, by = merge_keys, all.x = TRUE)

  # ---- Defective CDF values: y = quantile_level * choice_proportion ----
  cdf_df$y_obs      <- cdf_df$quantile * cdf_df$cp_obs
  cdf_df$y_pred_med <- cdf_df$quantile * cdf_df$cp_pred_med
  cdf_df$y_pred_lo  <- cdf_df$quantile * cdf_df$cp_pred_lo
  cdf_df$y_pred_hi  <- cdf_df$quantile * cdf_df$cp_pred_hi

  resp_labels <- c(T = "target", D = "difficult distractor", E = "easy distractor")
  cdf_df$resp_label <- factor(resp_labels[cdf_df$response_type], levels = resp_labels)
  cdf_df$facet_x    <- factor(cdf_df[[x_facet]])

  # Observed CDF: model-independent -- deduplicate so black line is drawn once
  obs_cdf <- unique(cdf_df[, c("experiment", x_facet, "search_difficulty",
                                "response_type", "resp_label", "facet_x",
                                "quantile", "obs", "y_obs")])
  obs_cdf$group_id <- interaction(obs_cdf$experiment, obs_cdf[[x_facet]],
                                   obs_cdf$search_difficulty, obs_cdf$response_type)

  # ---- Plot ----
  ggplot() +
    # Predicted: CI ribbon (y-axis) + median trace, one per model
    geom_ribbon(data = cdf_df,
                aes(x = pred_median, ymin = y_pred_lo, ymax = y_pred_hi,
                    group = model, fill = model),
                alpha = 0.15, colour = NA) +
    geom_line(data = cdf_df,
              aes(x = pred_median, y = y_pred_med, group = model, colour = model),
              linewidth = 0.8) +
    geom_point(data = cdf_df,
               aes(x = pred_median, y = y_pred_med, colour = model),
               size = 1.5) +
    # Observed: single black trace per panel
    geom_line(data = obs_cdf,
              aes(x = obs, y = y_obs, group = group_id),
              colour = "black", linewidth = 0.9) +
    geom_point(data = obs_cdf,
               aes(x = obs, y = y_obs),
               colour = "black", size = 2) +
    facet_grid(resp_label ~ facet_x) +
    scale_colour_manual(values = .model_colors) +
    scale_fill_manual(values = .model_colors) +
    labs(x = "RT (s)",
         y = "p(RT ≤ t,  R = r)",
         title = sprintf("Defective CDF by %s (step 4)", x_facet),
         subtitle = paste0("Black = observed; coloured = predicted median + 90% CI ",
                           "(reconstructed from QPF x choice proportion)")) +
    theme_bw(base_size = 12) +
    theme(legend.position = "bottom")
}
