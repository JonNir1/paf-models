#' =============================================================================
#' Fitting Orchestration: Parallelism, Persistence, Convergence, and Fitting
#'
#' Everything needed to run, checkpoint, and drive a hierarchical LBA fit to
#' convergence from a single entry point:
#'   - get_core_args()        runtime parallelism configuration
#'   - save_model()           date-stamped RDS serialisation
#'   - check_convergence()    generic per-group Rhat / ESS diagnostics
#'   - fit_to_convergence()   unified fit loop: warm up a fresh model OR resume a
#'                            pre-fitted one, then sample to convergence with
#'                            checkpointing + post-save hooks
#'   - model_log_path()       per-model log file path helper
#'
#' This single core replaces the old two-phase split (fit_initial -> fit_extend):
#' fit_to_convergence() takes an EMC2 object directly (not an .rds path) and
#' handles both newly-built (unfitted) and previously-fit models.
#'
#' Source chain: fitting.R -> build_model.R -> fit_config.R -> data.R -> logging.R -> config.R -> utils.R
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/build_model.R")


# -------------------------
#' Determine EMC2 parallelism arguments for the current machine.
#'
#' EMC2 only spawns one worker per chain, so cores_for_chains is capped at
#' n_chains -- extra cores beyond that are idle. Within-chain parallelism via
#' cores_per_chain (parallelises the per-participant likelihood) is available on
#' Linux/Mac only (EMC2 uses fork-based mclapply); on Windows it defaults to 1
#' and is a no-op. Passing 1 explicitly on Windows is safe (it is the default).
#'
#' @param n_chains Integer. Number of MCMC chains (N_CHAINS for new fits;
#'   length(model) for an existing fitted object).
#' @return Named list: cores_for_chains (integer), cores_per_chain (integer).
get_core_args <- function(n_chains) {
  total <- parallel::detectCores()
  if (is.na(total) || total < 1L) total <- 1L  # guard: containers can return NA

  cores_for_chains <- min(n_chains, total)
  on_windows       <- .Platform$OS.type == "windows"
  cores_per_chain  <- if (on_windows) 1L else max(1L, total %/% n_chains)

  list(cores_for_chains = cores_for_chains,
       cores_per_chain  = cores_per_chain)
}


# -------------------------
#' Save a fitted model as a date-stamped RDS file.
#' @param model       The fitted EMC2 model object.
#' @param name        Model name (non-date portion of the filename).
#' @param dir_path    Output directory; created recursively if absent.
#' @param date_prefix Optional 6-char YYMMDD string. Defaults to today. Pin this
#'   at the start of long-running calls so midnight crossings don't split saves
#'   into two filenames.
#' @return Full path to the saved file (usable for hook callbacks).
save_model <- function(model, name, dir_path, date_prefix = NULL) {
  if (!check_valid_string(name))     stop(sprintf("Invalid model name: %s", name))
  if (!check_valid_string(dir_path)) stop(sprintf("Invalid directory path: %s", dir_path))
  if (!dir.exists(dir_path)) dir.create(dir_path, recursive = TRUE)
  if (is.null(date_prefix)) date_prefix <- format(Sys.Date(), "%y%m%d")
  full_path <- file.path(dir_path, paste0(date_prefix, "_", name, ".rds"))
  saveRDS(model, full_path)
  return(full_path)
}


# -------------------------
#' Count iterations stored in the `sample` stage of an EMC2 model.
#' EMC2 labels every stored iteration with its stage in
#' model[[chain]]$samples$stage (a character vector); the convergence floor
#' (`num_samples`) is defined on the sample stage only, NOT on burn/adapt.
#' Returns 0 for a freshly-built make_emc() object (no samples yet).
.sample_iters <- function(model) {
  st <- tryCatch(model[[1L]]$samples$stage, error = function(e) NULL)
  if (is.null(st)) return(0L)
  as.integer(sum(st == "sample"))
}


# -------------------------
#' Total stored iterations (all stages) in an EMC2 model.
#' Used for logging only. Fails loudly if the expected structure is absent.
.get_n_iter <- function(model) {
  d <- tryCatch(dim(model[[1L]]$samples$theta_mu), error = function(e) NULL)
  if (!is.null(d) && length(d) >= 1L)
    return(as.integer(d[length(d)]))
  return(0L)
}


# -------------------------
#' Map a user-facing convergence-group key to EMC2's check()/get_pars() token.
#' Accepts case-insensitive aliases ("Sigma2"/"sigma2", "Mu"/"mu", ...).
.convergence_group_token <- function(key) {
  k <- tolower(key)
  switch(k,
         mu          = "mu",
         sigma2      = "sigma2",
         alpha       = "alpha",
         correlation = "correlation",
         stop(sprintf(
           "Unknown convergence group '%s'. Supported: mu, Sigma2, alpha, correlation.", key
         )))
}


# -------------------------
#' Pull max-Rhat and min-ESS for one EMC2 check() block.
#' EMC2 3.4.1 shapes (empirically confirmed):
#'   - mu / sigma2 / correlation: chk[[token]] is either a 2-row matrix
#'     (row 1 = Rhat, row 2 = ESS) or a list whose [[token]] element is that
#'     matrix (e.g. chk$mu$mu).
#'   - alpha: chk$alpha is a PER-SUBJECT list of 2-row matrices.
#' Verify against the installed EMC2 if a future selection changes shape.
.block_rhat_ess <- function(chk, token) {
  blk <- chk[[token]]
  if (is.null(blk))
    stop(sprintf("check() returned no '%s' block; cannot gate convergence on it.", token))

  if (token == "alpha") {
    rhat <- unlist(lapply(blk, function(x) x[1, ]))
    ess  <- unlist(lapply(blk, function(x) x[2, ]))
  } else {
    m    <- if (is.matrix(blk)) blk else blk[[token]]
    rhat <- m[1, ]
    ess  <- m[2, ]
  }
  list(max_rhat = max(rhat, na.rm = TRUE),
       min_ess  = min(ess,  na.rm = TRUE))
}


# -------------------------
#' Check convergence against a generic, per-group `convergence_criteria`.
#'
#' Each group present in `convergence_criteria` (other than `num_samples`) is
#' gated on its `max_rhat` / `min_ess`. Groups that are ABSENT are not gated --
#' i.e. they are treated as descriptive-only. This matches the project's
#' standing decision to report $sigma2 and $correlation descriptively (they are
#' inferentially irrelevant under the within-subject design) while enforcing
#' convergence on $mu and $alpha.
#'
#' @param model A fitted EMC2 model object.
#' @param convergence_criteria A list with optional per-group entries, e.g.
#'   list(num_samples = 3000,
#'        mu    = list(max_rhat = 1.05, min_ess = 500),
#'        alpha = list(max_rhat = 1.10, min_ess = 400)).
#'   The `num_samples` element is ignored here (it gates the sample floor in
#'   fit_to_convergence(), not Rhat/ESS).
#' @return List with `converged` (overall boolean) and `groups` (per-group list
#'   of max_rhat, min_ess, thresholds, and per-group `converged`).
check_convergence <- function(model, convergence_criteria) {
  library(EMC2)

  group_keys <- setdiff(names(convergence_criteria), "num_samples")
  if (length(group_keys) == 0L)
    stop("convergence_criteria gates no parameter groups (only num_samples given).")

  tokens <- vapply(group_keys, .convergence_group_token, character(1))

  capture.output(
    chk <- suppressWarnings(check(
      model, selection = unname(tokens), plot_worst = FALSE, digits = 4
    ))
  )

  groups        <- list()
  all_converged <- TRUE
  for (i in seq_along(group_keys)) {
    key  <- group_keys[[i]]
    spec <- convergence_criteria[[key]]
    if (is.null(spec$max_rhat) || is.null(spec$min_ess))
      stop(sprintf("convergence_criteria$%s must have numeric max_rhat and min_ess.", key))

    de        <- .block_rhat_ess(chk, tokens[[i]])
    converged <- de$max_rhat < spec$max_rhat && de$min_ess > spec$min_ess
    all_converged <- all_converged && converged

    groups[[key]] <- list(
      max_rhat     = de$max_rhat,
      min_ess      = de$min_ess,
      max_rhat_thr = spec$max_rhat,
      min_ess_thr  = spec$min_ess,
      converged    = converged
    )
  }

  list(converged = all_converged, groups = groups)
}


# -------------------------
#' Log one line per gated convergence group (max-Rhat / min-ESS vs threshold).
.log_convergence <- function(cv, log_file) {
  for (key in names(cv$groups)) {
    g <- cv$groups[[key]]
    log_msg(sprintf(
      "  %-11s Rhat=%.4f (<%.2f) | ESS=%.0f (>%d)  [%s]",
      key, g$max_rhat, g$max_rhat_thr, g$min_ess, g$min_ess_thr,
      ifelse(g$converged, "OK", "WAIT")
    ), log_file, console_print = TRUE)
  }
}


# -------------------------
#' Validate a convergence_criteria list. Fails fast with an informative message.
.validate_convergence_criteria <- function(cc) {
  if (!is.list(cc)) stop("convergence_criteria must be a list.")
  ns <- cc$num_samples
  if (is.null(ns) || !is.numeric(ns) || length(ns) != 1 || is.na(ns) || ns < 1 || ns != round(ns))
    stop("convergence_criteria$num_samples must be a positive integer.")
  group_keys <- setdiff(names(cc), "num_samples")
  if (length(group_keys) == 0L)
    stop("convergence_criteria must gate at least one group (e.g. mu, alpha).")
  for (key in group_keys) {
    .convergence_group_token(key)  # validates the key is supported
    spec <- cc[[key]]
    if (!is.list(spec) || is.null(spec$max_rhat) || is.null(spec$min_ess) ||
        !is.numeric(spec$max_rhat) || !is.numeric(spec$min_ess))
      stop(sprintf(
        "convergence_criteria$%s must be a list with numeric max_rhat and min_ess.", key
      ))
  }
  invisible(TRUE)
}


# -------------------------
#' Validate the scalar/path arguments to fit_to_convergence(). Pure (no EMC2,
#' no model object) so it is unit-testable at L1. Fails fast with informative
#' messages BEFORE any MCMC work begins.
#' @param n_samp_start Sample-stage iters already present in the model (>=0).
.validate_fit_args <- function(n_samp_start, num_samples, max_tries, batch_size,
                               save_every, save_path, post_save_hook) {
  if (!is.numeric(n_samp_start) || length(n_samp_start) != 1 || is.na(n_samp_start) ||
      n_samp_start < 0)
    stop("n_samp_start must be a non-negative number.")
  if (!is.numeric(max_tries) || length(max_tries) != 1 || is.na(max_tries) ||
      max_tries < 1 || max_tries != round(max_tries))
    stop("max_tries must be a positive integer.")
  if (!is.numeric(batch_size) || length(batch_size) != 1 || is.na(batch_size) ||
      batch_size < 1 || batch_size != round(batch_size))
    stop("batch_size must be a positive integer.")

  if (!is.null(save_every)) {
    if (!is.numeric(save_every) || length(save_every) != 1 || is.na(save_every) ||
        save_every < 1 || save_every != round(save_every))
      stop("save_every must be a positive integer or NULL.")
    if (save_every > max_tries)
      stop(sprintf(
        "save_every (%d) > max_tries (%d): no intermediate checkpoint would ever be written.",
        save_every, max_tries))
    if (is.null(save_path))
      stop("save_every is set but save_path is NULL: nowhere to write checkpoints.")
  }
  if (!is.null(post_save_hook) && !is.function(post_save_hook))
    stop("post_save_hook must be a function or NULL.")

  # The model can never reach the floor if the maximum addable sampling
  # (existing + batch_size * max_tries) falls short. Reject up front. This
  # bound is intentionally CONSERVATIVE for a fresh fit: fit_to_convergence()'s
  # warm-up EMC2::fit() call adds one extra batch_size of sample iters before
  # the try-loop even starts, so the true achievable ceiling for a fresh model
  # is batch_size*(max_tries+1), not batch_size*max_tries. A config that is
  # rejected here may therefore just barely reach the floor in practice for a
  # fresh model; this check does not know whether n_samp_start==0 means
  # "fresh" or "pre-fitted with zero stored sample iters".
  if (n_samp_start + batch_size * max_tries < num_samples)
    stop(sprintf(
      paste0("Convergence is unreachable: existing sample iters (%d) + ",
             "batch_size*max_tries (%d*%d=%d) < num_samples (%d). ",
             "Increase batch_size, max_tries, or lower num_samples."),
      n_samp_start, batch_size, max_tries, batch_size * max_tries, num_samples))

  invisible(TRUE)
}


# -------------------------
#' Fit an EMC2 model to convergence -- the single entry point for all fitting.
#'
#' Handles BOTH a freshly-built (unfitted) make_emc() object and a previously-fit
#' object:
#'   - Fresh model (no sample-stage iterations): runs the full EMC2 progression
#'     (preburn -> burn -> adapt -> an initial `batch_size` of sampling) via
#'     EMC2::fit(), then enters the convergence loop.
#'   - Pre-fitted model: skips straight to the convergence loop, adding sampling
#'     iterations until the criteria are met.
#'
#' Convergence requires BOTH: (1) every gated group in `convergence_criteria`
#' meets its Rhat/ESS thresholds, AND (2) the sample-stage iteration count per
#' chain reaches `convergence_criteria$num_samples`.
#'
#' Self-contained: takes all config as arguments so it is safe to call in
#' parallel (one process per model, no shared mutable state).
#'
#' @param emc                  An EMC2 model object (from make_emc(); may be
#'                             unfitted or already fitted).
#' @param convergence_criteria List: `num_samples` (sample-stage floor per chain)
#'                             plus per-group `list(max_rhat=, min_ess=)` entries
#'                             for any of mu / Sigma2 / alpha / correlation.
#'                             Omitted groups are descriptive-only (not gated).
#' @param max_tries            Maximum number of sampling batches to add.
#' @param batch_size           Sample-stage iterations added per try (and the
#'                             initial sample target when warming up a fresh model).
#' @param save_every           Checkpoint every N tries (in addition to the final
#'                             save). NULL => save only at the end. Requires
#'                             `save_path`. Must satisfy 1 <= save_every <= max_tries.
#' @param post_save_hook       NULL or function(rds_path, log_path) called after
#'                             every save; use for S3/GCS sync on cloud instances.
#' @param save_path            Full path to write the .rds checkpoints + final
#'                             save to (overwritten each time). NULL => no disk
#'                             writes (in-memory only; for tests / in-process use).
#' @param log_file             Path for timestamped progress lines, or NULL to log
#'                             to console only.
#' @param init_stop_criteria   Optional stop_criteria list forwarded to the
#'                             warm-up EMC2::fit() for a fresh model. NULL =>
#'                             EMC2 defaults (production). Smoke tests pass loose
#'                             criteria (e.g. list(max_gd = Inf)) so the warm-up
#'                             phases exit quickly on tiny chains.
#' @param append_log           If TRUE, append to log_file rather than truncating
#'                             it (e.g. when sharing a log with a caller).
#' @return List: model, saved_path (or NULL), diagnostics, n_tries, converged,
#'   n_samples (final sample-stage count), duration_min.
fit_to_convergence <- function(emc,
                               convergence_criteria = default_convergence_criteria(),
                               max_tries            = MAX_TRIES,
                               batch_size           = STEP_SIZE,
                               save_every           = NULL,
                               post_save_hook       = NULL,
                               save_path            = NULL,
                               log_file             = NULL,
                               init_stop_criteria   = NULL,
                               append_log           = FALSE) {
  library(EMC2)
  start_time <- Sys.time()

  # ---- Validate inputs BEFORE any heavy work (fail in ms, not hours) ----
  .validate_convergence_criteria(convergence_criteria)
  num_samples  <- convergence_criteria$num_samples
  n_samp_start <- .sample_iters(emc)
  .validate_fit_args(n_samp_start, num_samples, max_tries, batch_size,
                     save_every, save_path, post_save_hook)

  # ---- Logging setup ----
  if (!is.null(log_file)) cat("", file = log_file, append = append_log)
  n_chains  <- length(emc)
  core_args <- get_core_args(n_chains)
  log_msg(sprintf(
    "Core config: n_chains=%d, cores_for_chains=%d, cores_per_chain=%d (machine has %d cores)",
    n_chains, core_args$cores_for_chains, core_args$cores_per_chain, parallel::detectCores()),
    log_file, console_print = TRUE)
  log_msg(sprintf(
    "Targets: num_samples>=%d (sample stage) | gated groups: %s | batch_size=%d | max_tries=%d",
    num_samples, paste(setdiff(names(convergence_criteria), "num_samples"), collapse = ", "),
    batch_size, max_tries), log_file, console_print = TRUE)

  # Every checkpoint and the final save overwrite the same caller-supplied
  # save_path, so they always land in one place regardless of how long the
  # run takes or how many tries it spans. NULL save_path => no disk writes.
  do_save <- function(model, tag) {
    if (is.null(save_path)) return(invisible(NULL))
    dir_path <- dirname(save_path)
    if (!dir.exists(dir_path)) dir.create(dir_path, recursive = TRUE)
    saveRDS(model, save_path)
    log_msg(sprintf("%s: saved %s", tag, save_path), log_file, console_print = TRUE)
    if (!is.null(post_save_hook)) post_save_hook(save_path, log_file)
  }

  # ---- Phase A: warm up a fresh model into the sample stage ----
  # A freshly-built make_emc() object has no sample-stage iterations; EMC2::fit()
  # runs preburn -> burn -> adapt -> sample(batch_size) in one call (the same call
  # the retired fit_initial.R used). A pre-fitted model skips this entirely.
  if (n_samp_start == 0L) {
    log_msg(sprintf("Fresh model: warming up (burn/adapt) + initial %d sample iters...", batch_size),
            log_file, console_print = TRUE)
    emc <- fit(
      emc,
      cores_for_chains = core_args$cores_for_chains,
      cores_per_chain  = core_args$cores_per_chain,
      iter             = batch_size,
      stop_criteria    = init_stop_criteria
    )
    do_save(emc, "Post-warmup checkpoint")
  } else {
    log_msg(sprintf("Resuming pre-fitted model (%d sample iters present).", n_samp_start),
            log_file, console_print = TRUE)
  }

  # ---- Pre-loop convergence check ----
  # A sufficiently-sampled model may already satisfy all criteria; check once so
  # we don't waste a batch.
  cv        <- check_convergence(emc, convergence_criteria)
  n_samp    <- .sample_iters(emc)
  log_msg(sprintf("Initial check (%d sample iters):", n_samp), log_file, console_print = TRUE)
  .log_convergence(cv, log_file)

  converged <- FALSE
  try_idx   <- 0L
  if (cv$converged && n_samp >= num_samples) {
    converged <- TRUE
    log_msg(sprintf("Already converged at %d sample iters — no extension needed.", n_samp),
            log_file, console_print = TRUE)
  } else {
    # ---- Phase B: convergence loop ----
    # Add `batch_size` sampling iters per try, then evaluate our generic
    # per-group criteria. stop_criteria$iter is an ADDITIVE delta in EMC2's
    # sample stage (target = current + iter); max_gr/min_es are set trivially so
    # iter_done flips after one pass. max_tries=1 is a redundant inner bound --
    # the outer loop here owns the real try budget.
    for (try_idx in seq_len(max_tries)) {
      log_msg(sprintf("Try %d/%d: adding %d sample iters...", try_idx, max_tries, batch_size),
              log_file, console_print = TRUE)
      emc <- run_emc(
        emc,
        stage            = "sample",
        stop_criteria    = list(iter = batch_size, max_gr = 1.5, min_es = 1),
        max_tries        = 1,
        step_size        = batch_size,
        cores_for_chains = core_args$cores_for_chains,
        cores_per_chain  = core_args$cores_per_chain
      )

      cv     <- check_convergence(emc, convergence_criteria)
      n_samp <- .sample_iters(emc)
      .log_convergence(cv, log_file)

      if (!is.null(save_every) && try_idx %% save_every == 0L)
        do_save(emc, sprintf("Checkpoint after try %d", try_idx))

      floor_met <- n_samp >= num_samples
      if (cv$converged && floor_met) {
        converged <- TRUE
        log_msg(sprintf("Converged after %d tries (%d sample iters).", try_idx, n_samp),
                log_file, console_print = TRUE)
        break
      } else if (cv$converged && !floor_met) {
        log_msg(sprintf("  Rhat/ESS met but sample floor not reached: %d / %d.",
                        n_samp, num_samples), log_file, console_print = TRUE)
      }
    }
    if (!converged)
      log_msg(sprintf("Max tries (%d) exhausted without full convergence.", max_tries),
              log_file, console_print = TRUE)
  }

  # ---- Final save (always, regardless of save_every) ----
  do_save(emc, "Final save")

  duration_min <- as.numeric(difftime(Sys.time(), start_time, units = "mins"))
  log_msg(sprintf("Total runtime: %.2f minutes", duration_min), log_file, console_print = TRUE)

  list(
    model        = emc,
    saved_path   = save_path,
    diagnostics  = cv,
    n_tries      = try_idx,
    converged    = converged,
    n_samples    = n_samp,
    duration_min = duration_min
  )
}


# -------------------------
#' Build a per-model log file path under a fitting output directory.
#' Each fit invocation writes to its own log to avoid interleaving when running
#' multiple instances in parallel (one process per model).
model_log_path <- function(name, models_dir = MODELS_FIT_DIR) {
  base <- tools::file_path_sans_ext(basename(name))
  file.path(models_dir, paste0("log_fit_", base, ".txt"))
}
