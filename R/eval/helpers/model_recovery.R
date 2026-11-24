#' =========================
#' Model-Recovery Helpers
#' =========================
#' Pure computations behind R/eval/model_recovery.R: data simulated from each
#' generating model are refit with every candidate model; the candidate with the
#' highest marginal likelihood (bridge sampling, see helpers/bf.R) is the
#' "selected" model, and the generating x selected confusion matrix shows whether
#' model selection can tell the models apart.
#'
#'   recovery_group_problem() -- why a generating x sim group cannot be compared (or NULL)
#'   select_by_mll()    -- selected model per generating model x simulation
#'   confusion_table()  -- counts and row proportions of generating x selected
#'
#' Source chain: model_recovery.R (helpers) -> utils.R.

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))


#' Why the candidates of one generating x sim group cannot be compared, or NULL.
#'
#' They are comparable only if every candidate has a recovery fit and a
#' true_alpha file, and all true_alpha objects (matrix + provenance: source fit,
#' sim seed, RT window, template-data fingerprint) are identical, i.e. every
#' candidate was fit to the same simulated data.
#'
#' @param fits   Named character vector (names = candidates) of fit paths; NA = missing.
#' @param alphas Named list (names = candidates) of true_alpha objects; NULL = missing.
#' @return NULL if comparable, else a one-line reason.
recovery_group_problem <- function(fits, alphas) {
  absent <- union(names(fits)[is.na(fits)], names(alphas)[vapply(alphas, is.null, logical(1))])
  if (length(absent) > 0L)
    return(sprintf("no recovery fit or true_alpha for %s", paste(absent, collapse = ", ")))
  if (!all(vapply(alphas[-1L], identical, logical(1), alphas[[1L]])))
    return("candidates were fit to different simulated data (true_alpha or its provenance differs)")
  NULL
}


#' Model selected by the highest median MLL, per generating model x simulation.
#'
#' Each (generating, sim) group must hold exactly the same candidates (`fitted`)
#' as `models`, with finite MLLs; anything else is an error. Exact ties go to the
#' first candidate in `models` order.
#'
#' @param mll_df data.frame(generating, sim, fitted, mll_median[, mll_range]),
#'   one row per fitted candidate; `mll_range` = max - min over repetitions.
#' @param models Character vector of all candidate models.
#' @return data.frame(generating, sim, selected, correct, margin, spread), one
#'   row per group; `correct` = selected == generating; `margin` = best minus
#'   runner-up median MLL; `spread` = the larger repetition range of those two
#'   (NA without `mll_range`). A margin below the spread is a near-tie.
select_by_mll <- function(mll_df, models) {
  if (nrow(mll_df) == 0L) stop("select_by_mll: no MLLs.", call. = FALSE)
  groups <- split(mll_df, list(mll_df$generating, mll_df$sim), drop = TRUE, sep = "\r")
  out <- do.call(rbind, lapply(groups, function(d) {
    if (!setequal(d$fitted, models) || anyDuplicated(d$fitted) || !all(is.finite(d$mll_median)))
      stop(sprintf("select_by_mll: generating '%s' sim %s lacks a finite MLL for every candidate model.",
                   d$generating[1], d$sim[1]), call. = FALSE)
    d <- d[match(models, d$fitted), ]
    top <- order(-d$mll_median)[1:2]
    data.frame(generating = d$generating[1], sim = d$sim[1], selected = d$fitted[top[1]],
               margin = d$mll_median[top[1]] - d$mll_median[top[2]],
               spread = if (is.null(d$mll_range)) NA_real_ else max(d$mll_range[top]),
               stringsAsFactors = FALSE)
  }))
  out$correct <- out$selected == out$generating
  rownames(out) <- NULL
  out <- out[order(out$generating, out$sim), ]
  out[c("generating", "sim", "selected", "correct", "margin", "spread")]
}


#' Confusion table: how often each candidate was selected per generating model.
#'
#' @param selection Output of select_by_mll().
#' @param models    Character vector of all candidate models (selected levels).
#' @return data.frame(generating, selected, n, prop) with every generating x
#'   selected cell (zero counts included); `prop` = n / n_sims of that
#'   generating model.
confusion_table <- function(selection, models) {
  grid <- expand.grid(generating = sort(unique(selection$generating)), selected = models,
                      stringsAsFactors = FALSE)
  grid$n    <- mapply(function(g, s) sum(selection$generating == g & selection$selected == s),
                      grid$generating, grid$selected)
  grid$prop <- grid$n / ave(grid$n, grid$generating, FUN = sum)
  grid[order(grid$generating, match(grid$selected, models)), ]
}
