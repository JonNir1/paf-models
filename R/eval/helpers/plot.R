#' =========================
#' Evaluation Plot Helpers (ggplot2 + ragg)
#' =========================
#' ggplot2 figure builders for the step-2.9 review, plus a static-PNG exporter
#' via ragg (no Python/kaleido needed). Shared across eval scripts so figure
#' styling and export live in one place.
#'
#'   save_ggplot_png()           -- export a ggplot to PNG via ragg
#'   plot_convergence_summary()  -- Rhat/ESS vs thresholds, per model x block
#'   plot_recovery_scatter()     -- subject-level estimated vs true alpha
#'   plot_zscore_contraction()   -- Schad et al. 2021 z-score vs contraction
#'
#' Source chain: plot.R -> utils.R.
#' Convergence thresholds (MAX_RHAT_*, MIN_ESS_*) come from R/config.R via the caller.

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))

# Shared verdict palette (also used outside plotting for legends/tables).
VERDICT_COLORS <- c(pass = "#2c7fb8", marginal = "#f0a500",
                    fail = "#d7301f", descriptive = "#969696")


#' Export a ggplot to PNG via ragg (Cairo-free, no external toolchain).
#'
#' @param plot  A ggplot object.
#' @param path  Target .png path.
#' @param width,height Inches.
#' @param dpi   Resolution.
#' @return `path`, invisibly.
save_ggplot_png <- function(plot, path, width = 10, height = 7, dpi = 150) {
  if (!requireNamespace("ggplot2", quietly = TRUE)) stop("Package 'ggplot2' is required.")
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  dev <- if (requireNamespace("ragg", quietly = TRUE)) ragg::agg_png else "png"
  ggplot2::ggsave(path, plot, width = width, height = height, dpi = dpi, device = dev)
  message(sprintf("  Saved figure: %s", path))
  invisible(path)
}


#' Convergence summary: max Rhat and min ESS per model x block vs thresholds.
#'
#' Each marker is coloured by its OWN metric verdict (verdict_rhat for the Rhat
#' panel, verdict_ess for the ESS panel), and models are separated into bands.
#'
#' @param conv_table create_convergence_table() + add_convergence_verdict().
#' @return A ggplot, facet_grid(model ~ metric).
plot_convergence_summary <- function(conv_table) {
  library(ggplot2)
  d <- conv_table
  blk_levels <- c("correlation", "sigma2", "alpha", "mu")   # mu/alpha at top

  long <- rbind(
    data.frame(model = d$model, group = d$group, metric = "max Rhat",
               value = d$max_rhat, verdict = d$verdict_rhat),
    data.frame(model = d$model, group = d$group, metric = "min ESS",
               value = d$min_ess, verdict = d$verdict_ess)
  )
  long$group   <- factor(long$group, levels = blk_levels)
  long$verdict <- factor(long$verdict, levels = names(VERDICT_COLORS))

  thresh <- rbind(
    data.frame(metric = "max Rhat", xintercept = MAX_RHAT_MU,    block = "$mu"),
    data.frame(metric = "max Rhat", xintercept = MAX_RHAT_ALPHA, block = "$alpha"),
    data.frame(metric = "min ESS",  xintercept = MIN_ESS_MU,     block = "$mu"),
    data.frame(metric = "min ESS",  xintercept = MIN_ESS_ALPHA,  block = "$alpha")
  )

  ggplot(long, aes(value, group, color = verdict)) +
    geom_vline(data = thresh, aes(xintercept = xintercept, linetype = block),
               color = "grey40") +
    geom_point(size = 3) +
    facet_grid(model ~ metric, scales = "free_x") +
    scale_color_manual(values = VERDICT_COLORS, drop = FALSE, name = "verdict") +
    scale_linetype_manual(values = c("$mu" = "dashed", "$alpha" = "solid"),
                          name = "threshold") +
    labs(x = NULL, y = NULL,
         title = "Convergence vs asymmetric targets (per-metric verdict)",
         subtitle = "Marker colour = that metric's verdict; lines = $mu (dashed) / $alpha (solid) thresholds") +
    theme_bw(base_size = 12) +
    theme(panel.spacing.y = unit(0.6, "lines"),
          strip.text.y = element_text(angle = 0))
}


#' Subject-level recovery scatter: estimated vs true alpha, faceted by model.
#'
#' Points are coloured by whether the parameter is in the identifiable "core"
#' subspace; the structurally-unidentifiable StimulusAtLoc x SearchDifficulty
#' block (models 4/5) shows up as the off-diagonal red cloud.
#'
#' @param points_df Long: columns model, parameter, subject, true, est, identifiable.
#' @param stats_df  Optional per-model summary with r_all/rmse_all/r_core/rmse_core.
#' @return A ggplot.
plot_recovery_scatter <- function(points_df, stats_df = NULL) {
  library(ggplot2)
  if (is.null(points_df$identifiable)) points_df$identifiable <- TRUE
  points_df$id_lab <- ifelse(points_df$identifiable,
                             "core parameters", "StimulusAtLoc x SearchDifficulty block")

  p <- ggplot(points_df, aes(true, est, color = id_lab)) +
    geom_abline(slope = 1, intercept = 0, linetype = "dashed", color = "black") +
    geom_point(size = 1, alpha = 0.4) +
    facet_wrap(~model, scales = "free") +
    scale_color_manual(values = c("core parameters" = "#2c7fb8",
                                  "StimulusAtLoc x SearchDifficulty block" = "#d7301f"),
                       name = NULL) +
    labs(x = "True alpha", y = "Estimated alpha (posterior mean)",
         title = "Subject-level recovery: estimated vs true alpha",
         subtitle = "Red = the StimulusAtLoc x SearchDifficulty block - unidentifiable in models 4 & 5, identifiable in 1 & 2") +
    theme_bw(base_size = 12) +
    theme(legend.position = "bottom")

  if (!is.null(stats_df)) {
    stats_df$label <- sprintf("core: r %.2f, RMSE %.2f\nfull: r %.2f",
                              stats_df$r_core, stats_df$rmse_core, stats_df$r_all)
    p <- p + geom_text(
      data = stats_df, inherit.aes = FALSE,
      aes(x = -Inf, y = Inf, label = label),
      hjust = -0.05, vjust = 1.2, size = 3
    )
  }
  p
}


#' Per-model Pareto-k distribution (step-3 LOO diagnostic).
#'
#' Each trial contributes one k-hat value.  Vertical guides at 0.5 ("ok") and
#' 0.7 ("bad") follow the loo-package / Vehtari et al. 2017 convention.
#' Observations with k > 0.7 are coloured red to make the flag immediately
#' visible; the rest are blue.
#'
#' @param pareto_df data.frame with columns `model` (character) and `k_hat`
#'   (numeric), one row per trial.
#' @return A ggplot.
plot_pareto_k <- function(pareto_df) {
  library(ggplot2)
  pareto_df$bad <- pareto_df$k_hat > 0.7

  # Data-driven axis: show bulk of distribution while keeping 0.7 threshold
  # visible.  Use coord_cartesian (not xlim) so histogram bins are computed on
  # the full data before zooming -- outliers are clipped, not dropped.
  k_lo <- max(floor(quantile(pareto_df$k_hat, 0.001) * 10) / 10, -0.5)
  k_hi <- max(0.8, ceiling(quantile(pareto_df$k_hat, 0.999) * 10) / 10)

  ggplot(pareto_df, aes(k_hat, fill = bad)) +
    geom_histogram(bins = 40, color = "white", linewidth = 0.2) +
    geom_vline(xintercept = 0.5, linetype = "dashed",  color = "orange") +
    geom_vline(xintercept = 0.7, linetype = "solid",   color = "red") +
    facet_wrap(~model, scales = "free_y") +
    coord_cartesian(xlim = c(k_lo, k_hi)) +
    scale_fill_manual(values = c("FALSE" = "#2c7fb8", "TRUE" = "#d7301f"),
                      labels = c("FALSE" = "k <= 0.7", "TRUE" = "k > 0.7"),
                      name = NULL) +
    labs(x = "Pareto k", y = "Count",
         title = "Pareto-k diagnostic per model (step 3 LOO)",
         subtitle = "Orange dashed = 0.5 ('ok'); red solid = 0.7 ('bad', Vehtari et al. 2017). X-axis clipped to 99.9th percentile.") +
    theme_bw(base_size = 12) +
    theme(legend.position = "bottom")
}


#' LOO-CV ELPD comparison across models (step-3 model selection).
#'
#' Displays pairwise ELPD differences relative to the best model (elpd_diff = 0)
#' with ± 2 SE error bars.  A difference of |elpd_diff| < 2 * se_diff is
#' practically indistinguishable.
#'
#' @param loo_comp_df data.frame from make_loo_comparison_df(): columns
#'   `model`, `elpd_diff`, `se_diff`.
#' @return A ggplot.
plot_loo_comparison <- function(loo_comp_df) {
  library(ggplot2)
  df <- loo_comp_df
  df$model <- factor(df$model, levels = rev(df$model))  # best model at top
  ggplot(df, aes(elpd_diff, model)) +
    geom_vline(xintercept = 0, linetype = "dashed", color = "grey40") +
    geom_errorbar(aes(xmin = elpd_diff - 2 * se_diff,
                      xmax = elpd_diff + 2 * se_diff),
                  width = 0.2, color = "#2c7fb8") +
    geom_point(size = 3, color = "#2c7fb8") +
    labs(x = "ELPD difference vs best model",
         y = NULL,
         title = "LOO-CV ELPD model comparison (step 3)",
         subtitle = "Error bars = +/- 2 SE; reference model at 0") +
    theme_bw(base_size = 12)
}


#' Posterior z-score vs contraction (Schad, Betancourt & Vasishth 2021).
#'
#' @param zscore_df Columns model, parameter, z_score, contraction.
#' @return A ggplot with +/-2 z bands and a 0.5 contraction guide.
plot_zscore_contraction <- function(zscore_df) {
  library(ggplot2)
  ggplot(zscore_df, aes(contraction, z_score, color = model)) +
    geom_hline(yintercept = 0, color = "grey60") +
    geom_hline(yintercept = c(-2, 2), linetype = "dashed", color = "red") +
    geom_vline(xintercept = 0.5, linetype = "dotted", color = "orange") +
    geom_point(size = 2, alpha = 0.7) +
    coord_cartesian(xlim = c(0, 1), ylim = c(-3.5, 3.5)) +
    labs(x = "Posterior contraction (1 - var_post / var_prior)",
         y = "Posterior z-score ((est - true) / SD_post)",
         title = "Posterior z-score vs contraction (Schad et al. 2021)") +
    theme_bw(base_size = 12)
}
