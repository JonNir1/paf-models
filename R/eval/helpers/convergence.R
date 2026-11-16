#' =========================
#' Convergence Diagnostics Helpers
#' =========================
#' Helper functions for extracting and parsing MCMC convergence diagnostics
#' (Rhat & ESS) from fitted EMC2 models, and for rendering a step-2.9 verdict.
#'
#'   create_convergence_table()  -- unified Rhat/ESS table across models x blocks
#'   add_convergence_verdict()   -- append pass/marginal/descriptive per block
#'   extract_convergence_tables()-- per-model Rhat & ESS tables from check()
#'
#' "Block" = EMC2 parameter group: $mu (population means), $alpha (subject-level),
#' $sigma2 (between-subject variances), $correlation. The 2.9 decision rests only
#' on $mu and $alpha; $sigma2/$correlation are descriptive.
#'
#' Goodness-of-fit / model comparison (DIC, BPIC, ...) lives separately in
#' R/eval/model_comparison.R (step-3 scaffolding), NOT here.
#'
#' Source chain: convergence.R -> utils.R, emc2_api.R.
#' Convergence thresholds (MAX_RHAT_MU, ...) come from R/config.R via the caller.

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/helpers/emc2_api.R")       # emc_check, check_block_values


#' Create a single table comparing convergence metrics across models and blocks.
#' @param model_list A named list of models, e.g. list(model1 = M1, model5 = M5).
#' @return data.frame: one row per model x block, with Rhat & ESS summary columns.
create_convergence_table <- function(model_list) {
  master_results <- lapply(names(model_list), function(m_name) {
    diag_tables <- extract_convergence_tables(model_list[[m_name]])
    combined_groups <- merge(
      diag_tables$Rhat, diag_tables$ESS, by = c("group", "n_params")
    )
    data.frame(model = m_name, combined_groups)
  })
  do.call(rbind, master_results)
}


#' Per-metric convergence verdict for one block (pure).
#'
#' @param group   Block name: "mu","alpha","sigma2","correlation".
#' @param metric  "rhat" (uses `value` = max Rhat) or "ess" (uses `value` = min ESS).
#' @param value   The metric value (max Rhat or min ESS for the block).
#' @param p_rhat_hi Percent of block params with Rhat > 1.01 (Rhat metric only).
#' @param thresholds Named list rhat_mu/ess_mu/rhat_alpha/ess_alpha.
#' @param n_nonfinite Count of non-finite values in the block; any => "fail".
#' @return "pass" / "marginal" / "fail" / "descriptive".
metric_verdict <- function(group, metric, value, p_rhat_hi = 0, thresholds, n_nonfinite = 0) {
  if (group %in% c("sigma2", "correlation")) return("descriptive")
  if (!group %in% c("mu", "alpha"))          return(NA_character_)
  if (!is.finite(value) || n_nonfinite > 0)  return("fail")

  if (metric == "rhat") {
    ceil <- if (group == "mu") thresholds$rhat_mu else thresholds$rhat_alpha
    if (value > ceil)                              return("fail")
    if (value > ceil - 0.005 || isTRUE(p_rhat_hi > 25)) return("marginal")
    return("pass")
  }
  if (metric == "ess") {
    floor <- if (group == "mu") thresholds$ess_mu else thresholds$ess_alpha
    if (value < floor)        return("fail")
    if (value < floor * 1.10) return("marginal")  # within 10% of the floor
    return("pass")
  }
  stop("metric must be 'rhat' or 'ess'")
}


#' Append step-2.9 convergence verdicts to a convergence table.
#'
#' Adds three columns:
#'   - verdict_rhat : per-block verdict from the Rhat metric alone
#'   - verdict_ess  : per-block verdict from the ESS metric alone
#'   - verdict      : combined block verdict (descriptive, or the WORSE of the two
#'                    metric verdicts: fail > marginal > pass)
#'
#' This separation lets figures colour the Rhat and ESS markers independently
#' (e.g. model5$mu is marginal on Rhat but passes on ESS).
#'
#' Thresholds default to the R/config.R globals; pass explicit values for unit tests.
#'
#' @param conv_table     Output of create_convergence_table().
#' @param max_rhat_mu,min_ess_mu,max_rhat_alpha,min_ess_alpha Threshold overrides.
#' @return conv_table with verdict_rhat, verdict_ess, verdict columns.
add_convergence_verdict <- function(conv_table,
                                    max_rhat_mu    = MAX_RHAT_MU,
                                    min_ess_mu     = MIN_ESS_MU,
                                    max_rhat_alpha = MAX_RHAT_ALPHA,
                                    min_ess_alpha  = MIN_ESS_ALPHA) {
  th <- list(rhat_mu = max_rhat_mu, ess_mu = min_ess_mu,
             rhat_alpha = max_rhat_alpha, ess_alpha = min_ess_alpha)

  n_bad_rhat <- if (is.null(conv_table$n_nonfinite_rhat)) 0 else conv_table$n_nonfinite_rhat
  n_bad_ess  <- if (is.null(conv_table$n_nonfinite_ess))  0 else conv_table$n_nonfinite_ess

  conv_table$verdict_rhat <- mapply(
    function(g, v, p, n) metric_verdict(g, "rhat", v, p, th, n),
    conv_table$group, conv_table$max_rhat, conv_table$p_rhat_gt_1.01, n_bad_rhat,
    SIMPLIFY = TRUE, USE.NAMES = FALSE
  )
  conv_table$verdict_ess <- mapply(
    function(g, v, n) metric_verdict(g, "ess", v, thresholds = th, n_nonfinite = n),
    conv_table$group, conv_table$min_ess, n_bad_ess,
    SIMPLIFY = TRUE, USE.NAMES = FALSE
  )

  rank <- c(pass = 1L, marginal = 2L, fail = 3L)
  conv_table$verdict <- mapply(function(g, vr, ve) {
    if (g %in% c("sigma2", "correlation")) return("descriptive")
    if (is.na(vr) || is.na(ve)) return(NA_character_)
    names(rank)[max(rank[vr], rank[ve])]
  }, conv_table$group, conv_table$verdict_rhat, conv_table$verdict_ess,
  SIMPLIFY = TRUE, USE.NAMES = FALSE)

  conv_table
}


#' Extract convergence summary tables (Rhat & ESS) for a single fitted model.
#' @param model   The fitted EMC2 model object.
#' @param verbose If TRUE, print the full check() output to console.
#' @return list(Rhat = <df>, ESS = <df>), one row per block.
extract_convergence_tables <- function(model, verbose = FALSE) {
  selection_groups <- c("mu", "sigma2", "alpha", "correlation")
  check_call <- function() {
    suppressWarnings(
      emc_check(model, selection = selection_groups, plot_worst = FALSE, digits = 4)
    )
  }
  if (verbose) {
    chk <- check_call()
  } else {
    capture.output(chk <- check_call())   # silence console print, keep the object
  }

  rhat_table <- do.call(rbind, lapply(selection_groups, function(g) {
    vals  <- check_block_values(chk, g, 1)   # row 1 = Rhat
    stats <- .calc_summary_stats(vals, "Rhat")
    cbind(group = g, stats)
  }))
  ess_table <- do.call(rbind, lapply(selection_groups, function(g) {
    vals  <- check_block_values(chk, g, 2)   # row 2 = ESS
    stats <- .calc_summary_stats(vals, "ESS")
    cbind(group = g, stats)
  }))

  list(Rhat = rhat_table, ESS = ess_table)
}


#' Internal: summary stats for a numeric vector of Rhat or ESS values.
#' max/min/mean are over finite values (NA if none); `n_nonfinite_*` counts the rest.
.calc_summary_stats <- function(vals, type = c("Rhat", "ESS")) {
  type <- match.arg(type)
  n    <- length(vals)
  fin  <- vals[is.finite(vals)]
  stat <- function(fn) if (length(fin) > 0L) fn(fin) else NA_real_

  if (type == "Rhat") {
    data.frame(
      n_params         = n,
      max_rhat         = stat(max),
      mean_rhat        = stat(mean),
      n_nonfinite_rhat = sum(!is.finite(vals)),
      n_rhat_gt_1.1    = sum(vals > 1.1, na.rm = TRUE),
      p_rhat_gt_1.1    = (sum(vals > 1.1, na.rm = TRUE) / n) * 100,
      n_rhat_gt_1.01   = sum(vals > 1.01, na.rm = TRUE),
      p_rhat_gt_1.01   = (sum(vals > 1.01, na.rm = TRUE) / n) * 100
    )
  } else {
    data.frame(
      n_params        = n,
      min_ess         = stat(min),
      mean_ess        = stat(mean),
      n_nonfinite_ess = sum(!is.finite(vals)),
      n_ess_lt_500    = sum(vals < 500, na.rm = TRUE),
      p_ess_lt_500    = (sum(vals < 500, na.rm = TRUE) / n) * 100,
      n_ess_lt_1000   = sum(vals < 1000, na.rm = TRUE),
      p_ess_lt_1000   = (sum(vals < 1000, na.rm = TRUE) / n) * 100
    )
  }
}
