#' =========================
#' Bayes-Factor Helpers (bridge sampling)
#' =========================
#' Marginal-likelihood computations behind the BF driver (R/eval/bayes_factors.R),
#' the model-recovery driver and the cloud runner (R/fit/fit_bf_cloud.R). The
#' bridge-sampling estimate is expensive, so it is computed once per fit and
#' stored as a small MLL file; consumers read it back and only compute locally
#' when it is missing.
#'
#'   bridge_core_args()   -- cores for EMC2's Warp-III bridge sampling (auto-detected)
#'   compute_mll()        -- log marginal likelihood, one value per repetition
#'   mll_pattern()        -- regex of one fit's MLL files
#'   read_mll()           -- latest MLL record of a fit (NULL if absent, stale or too few reps)
#'   get_mll()            -- read_mll(), else compute locally (only if ALLOW_LOCAL_MLL) and write it
#'   run_mll()            -- compute + write the MLL record of one fit .rds
#'   bf_table()           -- per-model MLL summary and log-BF vs a reference model
#'
#' MLL files live in MODELS_BF_DIR as `YYMMDD_<stem>_mll.rds` where `<stem>` is
#' model_name_from_rds() of the fit file (e.g. `mymodel`, or a recovery fit's
#' `mymodel_recovery_sim1_fit_other`). Each is a list:
#'   model, fit_file (basename of the fit it came from), fit_md5 (content
#'   fingerprint of that file), emc2_version, reps, seed, mll (numeric, length
#'   `reps`), n_split_warnings (bridge-sampling split-disagreement warnings).
#' A record is current only if fit_file AND fit_md5 match the fit and `reps` is
#' at least the requested repetitions (a same-day refit keeps the file name).
#'
#' Pre-settable: ALLOW_LOCAL_MLL (default FALSE) lets get_mll() run bridge
#' sampling locally (hours); otherwise a missing MLL is an error.
#'
#' Source chain: bf.R -> utils.R, eval_config.R (RNG_*, MODELS_BF_DIR), emc2_api.R,
#' io.R (EMC2 only via emc_bridge_sampling()).

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")
source_root("R/helpers/emc2_api.R")
source_root("R/eval/helpers/io.R")

if (!exists("ALLOW_LOCAL_MLL")) ALLOW_LOCAL_MLL <- FALSE


#' Cores for run_bridge_sampling(): its 4 proposal densities in parallel
#' (`cores_for_props`), the remaining cores across subjects (`cores_per_prop`,
#' fork-based, so 1 on Windows). Auto-detected, like get_core_args().
#'
#' @return list(cores_for_props, cores_per_prop).
bridge_core_args <- function() {
  total <- parallel::detectCores()
  if (is.na(total) || total < 1L) total <- 1L
  props <- min(4L, total)
  list(cores_for_props = props,
       cores_per_prop  = if (.Platform$OS.type == "windows") 1L else max(1L, total %/% props))
}


#' Log marginal likelihood of a fitted model by Warp-III bridge sampling.
#'
#' @param emc   Fitted EMC2 object (converged sample stage).
#' @param reps  Number of bridge-sampling repetitions (their spread shows the
#'   estimate's stability).
#' @param seed  RNG seed set just before sampling (reproducibility).
#' @param cores Output of bridge_core_args().
#' @return Numeric vector of length `reps` (finite), one log MLL per repetition,
#'   with attribute `n_split_warnings`: how many times EMC2 warned that the two
#'   split estimates differ by more than 1 log point (unstable chains).
compute_mll <- function(emc, reps, seed = RNG_SEED, cores = bridge_core_args()) {
  if (!is.numeric(reps) || length(reps) != 1L || is.na(reps) || reps < 1L)
    stop("reps must be a single positive integer.", call. = FALSE)
  RNGkind(RNG_KIND)
  set.seed(seed)
  n_split <- 0L
  mll <- withCallingHandlers(
    as.numeric(emc_bridge_sampling(emc, stage = "sample", repetitions = reps,
                                   cores_for_props = cores$cores_for_props,
                                   cores_per_prop  = cores$cores_per_prop)),
    warning = function(w) {
      if (!grepl("off by 1 log point", conditionMessage(w), fixed = TRUE)) return()
      n_split <<- n_split + 1L
      invokeRestart("muffleWarning")
    })
  if (length(mll) != reps || !all(is.finite(mll)))
    stop(sprintf("Bridge sampling returned %d value(s), %d non-finite (expected %d finite).",
                 length(mll), sum(!is.finite(mll)), reps), call. = FALSE)
  structure(mll, n_split_warnings = n_split)
}


#' Regex of the MLL files of one fit, `YYMMDD_<stem>_mll.rds` (stem matched literally).
#'
#' @param stem model_name_from_rds() of the fit file.
mll_pattern <- function(stem) {
  sprintf("^[0-9]{6}_%s_mll\\.rds$", regex_escape(stem))
}


#' Latest MLL record of a fit and why it is (not) usable.
#'
#' @inheritParams read_mll
#' @return list(record, reason): `record` is the MLL record if current, else NULL;
#'   `reason` is NULL if current, else why not (no file / other fit file name /
#'   other file content (md5) / fewer than `reps` repetitions).
mll_status <- function(fit_path, reps = 1L, dir = MODELS_BF_DIR) {
  stale <- function(reason) list(record = NULL, reason = reason)
  if (!dir.exists(dir)) return(stale(sprintf("no MLL directory %s", dir)))
  path <- latest_dated_file(dir, mll_pattern(model_name_from_rds(fit_path)))
  if (is.na(path)) return(stale(sprintf("no MLL file in %s", dir)))
  record <- readRDS(path)
  if (!identical(record$fit_file, basename(fit_path)))
    return(stale(sprintf("latest MLL file %s was computed from fit file '%s'",
                         basename(path), record$fit_file)))
  if (!identical(record$fit_md5, fit_md5(fit_path)))
    return(stale(sprintf("latest MLL file %s was computed from different file content (md5 mismatch)",
                         basename(path))))
  if (is.null(record$reps) || record$reps < reps)
    return(stale(sprintf("latest MLL file %s has %s repetitions, %d required",
                         basename(path), record$reps %||% 0L, reps)))
  list(record = record, reason = NULL)
}


#' Latest MLL record of a fit, or NULL if there is none, it came from another
#' fit file or other file content (md5), or it has fewer than `reps` repetitions
#' (see mll_status() for the reason).
#'
#' @param fit_path Path of the fit .rds.
#' @param reps     Minimum repetitions the record must hold.
#' @param dir      Directory of MLL files (default MODELS_BF_DIR).
#' @return The MLL record (see the file header) or NULL.
read_mll <- function(fit_path, reps = 1L, dir = MODELS_BF_DIR) mll_status(fit_path, reps, dir)$record


#' Content fingerprint of a fit file (unnamed md5 string).
#'
#' @param fit_path Path of the fit .rds.
fit_md5 <- function(fit_path) unname(tools::md5sum(fit_path))


#' Compute the MLL of one fit .rds and write its record to `out_dir`.
#'
#' @param fit_path Path of the fit .rds.
#' @param reps     Bridge-sampling repetitions.
#' @param out_dir  Output directory (default MODELS_BF_DIR).
#' @param seed     RNG seed (default RNG_SEED).
#' @return Path of the written `YYMMDD_<stem>_mll.rds`.
run_mll <- function(fit_path, reps, out_dir = MODELS_BF_DIR, seed = RNG_SEED) {
  if (!file.exists(fit_path)) stop(sprintf("Fit not found: %s", fit_path), call. = FALSE)
  stem   <- model_name_from_rds(fit_path)
  mll    <- compute_mll(readRDS(fit_path), reps, seed)
  record <- list(model = stem, fit_file = basename(fit_path), fit_md5 = fit_md5(fit_path),
                 emc2_version = emc_version(), reps = as.integer(reps), seed = seed,
                 mll = as.numeric(mll), n_split_warnings = attr(mll, "n_split_warnings"))
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
  out_path <- file.path(out_dir, sprintf("%s_%s_mll.rds", format(Sys.Date(), "%y%m%d"), stem))
  saveRDS(record, out_path)
  out_path
}


#' MLL record of a fit: the precomputed file if there is a current one with at
#' least `reps` repetitions, else (only if ALLOW_LOCAL_MLL) computed here (slow)
#' and written first.
#'
#' @param fit_path Path of the fit .rds.
#' @param reps     Repetitions required (and used when computing).
#' @return The MLL record (see the file header).
get_mll <- function(fit_path, reps) {
  status <- mll_status(fit_path, reps)
  if (!is.null(status$record)) return(status$record)
  if (!isTRUE(ALLOW_LOCAL_MLL))
    stop(sprintf(paste0("No current MLL (>= %d repetitions) for %s: %s. Compute it on the cloud with ",
                        "scripts/run_bf.sh, or set ALLOW_LOCAL_MLL <- TRUE to run bridge sampling ",
                        "locally (hours)."),
                 reps, basename(fit_path), status$reason), call. = FALSE)
  message(sprintf("No current MLL file for %s; computing locally (%d bridge-sampling repetitions; slow)...",
                  basename(fit_path), reps))
  run_mll(fit_path, reps)
  read_mll(fit_path, reps)
}


#' Per-model MLL summary and log Bayes factors against a reference model.
#'
#' `log_bf_*` = log BF of the model over the reference (positive favours the
#' model): the median uses the median MLLs; min/max are the conservative envelope
#' over all repetition pairs (model min - reference max, model max - reference min),
#' so an interval excluding 0 is robust to the bridge-sampling noise. `post_prob`
#' is the posterior model probability under equal prior odds (softmax of the
#' median MLLs). Repetitions are independent runs, so no pairing is implied.
#'
#' @param mll_list  Named list (names = models) of numeric MLL vectors.
#' @param reference Model name to compare against; NULL = the model with the
#'   highest median MLL.
#' @param n_split_warnings Optional named vector (names = models) of bridge-sampling
#'   split warnings per model; NA column when NULL.
#' @return data.frame(model, reference, n_reps, mll_median, mll_min, mll_max,
#'   mll_sd, log_bf_median, log_bf_min, log_bf_max, post_prob, n_split_warnings),
#'   best median first.
bf_table <- function(mll_list, reference = NULL, n_split_warnings = NULL) {
  if (length(mll_list) == 0L || is.null(names(mll_list)))
    stop("mll_list must be a non-empty named list.", call. = FALSE)
  med <- vapply(mll_list, stats::median, numeric(1))
  if (is.null(reference)) reference <- names(which.max(med))
  if (!reference %in% names(mll_list))
    stop(sprintf("Reference model '%s' has no MLL (models: %s).",
                 reference, paste(names(mll_list), collapse = ", ")), call. = FALSE)
  ref <- mll_list[[reference]]
  w   <- exp(med - max(med))

  out <- do.call(rbind, lapply(names(mll_list), function(m) {
    x <- mll_list[[m]]
    data.frame(model = m, reference = reference, n_reps = length(x),
               mll_median = med[[m]], mll_min = min(x), mll_max = max(x),
               mll_sd = if (length(x) > 1L) stats::sd(x) else NA_real_,
               log_bf_median = med[[m]] - stats::median(ref),
               log_bf_min = min(x) - max(ref), log_bf_max = max(x) - min(ref),
               post_prob = w[[m]] / sum(w),
               n_split_warnings = if (is.null(n_split_warnings)) NA_integer_ else as.integer(n_split_warnings[[m]]),
               stringsAsFactors = FALSE)
  }))
  out <- out[order(-out$mll_median), ]
  rownames(out) <- NULL
  out
}
