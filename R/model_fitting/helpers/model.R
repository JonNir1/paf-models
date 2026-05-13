#' =============================================================================
#' EMC2 Model Construction, Fitting, Diagnostics, and Persistence
#'
#' Everything needed to build, run, evaluate, and save hierarchical LBA models.
#' Covers: runtime parallelism configuration (cores_for_chains / cores_per_chain),
#' the shared model-variant factory (build_lba_model) that owns the boilerplate
#' common to all five PAF model variants, asymmetric per-block convergence
#' checking ($mu vs $alpha), and date-stamped RDS serialisation.
#' =============================================================================

local({
  root <- Sys.getenv("PAF_REPO_ROOT", unset = "")
  if (nzchar(root)) {
    source(file.path(root, "R", "config.R"))
    source(file.path(root, "R", "model_fitting", "helpers", "data.R"))
  } else {
    source("R/config.R")
    source("R/model_fitting/helpers/data.R")  # chains: data.R -> logging.R
  }
})


# -------------------------
#' Determine EMC2 parallelism arguments for the current machine.
#'
#' EMC2 only spawns one worker per chain, so cores_for_chains is capped at
#' n_chains — extra cores beyond that are idle. Within-chain parallelism via
#' cores_per_chain (parallelises the per-participant likelihood) is available on
#' Linux/Mac only (EMC2 uses fork-based mclapply); on Windows it defaults to 1
#' and is a no-op. Passing 1 explicitly on Windows is safe (it is the default).
#'
#' @param n_chains Integer. Number of MCMC chains (N_CHAINS for new fits;
#'   length(model) for extending an existing fitted object).
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
#' Factory for all PAF LBA model variants.
#'
#' Owns the shared boilerplate (base priors, design, prior object, make_emc).
#' Each modelN.R passes only what differs: the v and B formulas plus any
#' model-specific prior entries beyond the shared base.
#'
#' Fixed across all variants (never vary, so hardcoded here):
#'   sv ~ StimulusAtLoc,  A ~ 1,  t0 ~ 1
#'
#' @param data       Data frame returned by filter_data().
#' @param v_formula  Formula object for drift rate, e.g.
#'                   `v ~ PrevTargetAtLoc + CueAtLoc + StimulusAtLoc`.
#' @param B_formula  Formula object for threshold, e.g. `B ~ 1` or
#'                   `B ~ SearchDifficulty`.
#' @param extra_mu   Named numeric vector of prior means for model-specific
#'                   parameters (appended to the shared base). Default `c()`.
#' @param extra_sd   Named numeric vector of prior SDs, parallel to `extra_mu`.
#' @param n_chains   Passed to make_emc(). Default 3.
#' @return An emc object ready for fit() / run_emc().
build_lba_model <- function(data,
                            v_formula,
                            B_formula,
                            extra_mu  = c(),
                            extra_sd  = c(),
                            n_chains  = 3) {

  library(EMC2)

  # --- Base priors (shared by all model variants) ---
  base_mu <- c(
    v                     = V_BASELINE_MU,
    v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_MU,
    v_CueAtLocSMALL       = V_CUE_S_MU,
    v_CueAtLocMEDIUM      = V_CUE_M_MU,
    v_CueAtLocLARGE       = V_CUE_L_MU,
    v_StimulusAtLocD      = V_STIM_D_MU,
    v_StimulusAtLocE      = V_STIM_E_MU,
    sv_StimulusAtLocD     = SV_STIM_D_MU,
    sv_StimulusAtLocE     = SV_STIM_E_MU,
    B                     = B_BASELINE_MU,
    A                     = A_MU,
    t0                    = T0_MU
  )
  base_sd <- c(
    v                     = V_BASELINE_SD,
    v_PrevTargetAtLocTRUE = V_PREVTAR_TRUE_SD,
    v_CueAtLocSMALL       = V_CUE_S_SD,
    v_CueAtLocMEDIUM      = V_CUE_M_SD,
    v_CueAtLocLARGE       = V_CUE_L_SD,
    v_StimulusAtLocD      = V_STIM_D_SD,
    v_StimulusAtLocE      = V_STIM_E_SD,
    sv_StimulusAtLocD     = SV_STIM_D_SD,
    sv_StimulusAtLocE     = SV_STIM_E_SD,
    B                     = B_BASELINE_SD,
    A                     = A_SD,
    t0                    = T0_SD
  )

  mu    <- c(base_mu, extra_mu)
  Sigma <- c(base_sd, extra_sd)

  # --- Design ---
  LBA_design <- design(
    data      = data,
    model     = LBA,
    constants = CONSTANTS,
    functions = list(
      PrevTargetAtLoc  = PrevTargetAtLoc,
      CueAtLoc         = CueAtLoc,
      StimulusAtLoc    = StimulusAtLoc,
      SearchDifficulty = SearchDifficulty
    ),
    formula = list(
      v_formula,
      sv ~ StimulusAtLoc,
      B_formula,
      A  ~ 1,
      t0 ~ 1
    )
  )

  # --- Prior ---
  LBA_prior <- prior(LBA_design, type = "standard", mu_mean = mu, mu_sd = Sigma)

  # --- Model object ---
  make_emc(data, design = LBA_design, prior = LBA_prior, n_chains = n_chains)
}


# -------------------------
#' Check $mu and $alpha convergence against block-specific Rhat/ESS thresholds.
#' $sigma2 and $correlation are intentionally NOT checked - per the within-subject
#' OOD design they are inferentially irrelevant; report them descriptively post-fit.
#'
#' @param model A fitted EMC2 model object.
#' @param max_rhat_mu,min_ess_mu     Thresholds for the population mean ($mu) block.
#' @param max_rhat_alpha,min_ess_alpha Thresholds for the subject-level ($alpha) block.
#' @return List with per-block diagnostics and an overall `converged` boolean.
check_block_convergence <- function(model,
                                    max_rhat_mu, min_ess_mu,
                                    max_rhat_alpha, min_ess_alpha) {
  library(EMC2)

  capture.output(
    chk <- suppressWarnings(check(
      model, selection = c("mu", "alpha"), plot_worst = FALSE, digits = 4
    ))
  )
  mu_rhat    <- chk[["mu"]][["mu"]][1, ]
  mu_ess     <- chk[["mu"]][["mu"]][2, ]
  alpha_rhat <- unlist(lapply(chk$alpha, function(x) x[1, ]))
  alpha_ess  <- unlist(lapply(chk$alpha, function(x) x[2, ]))

  mu_max_rhat    <- max(mu_rhat,    na.rm = TRUE)
  mu_min_ess     <- min(mu_ess,     na.rm = TRUE)
  alpha_max_rhat <- max(alpha_rhat, na.rm = TRUE)
  alpha_min_ess  <- min(alpha_ess,  na.rm = TRUE)

  mu_converged    <- mu_max_rhat    < max_rhat_mu    && mu_min_ess    > min_ess_mu
  alpha_converged <- alpha_max_rhat < max_rhat_alpha && alpha_min_ess > min_ess_alpha

  list(
    converged       = mu_converged && alpha_converged,
    mu_converged    = mu_converged,
    alpha_converged = alpha_converged,
    mu_max_rhat     = mu_max_rhat,
    mu_min_ess      = mu_min_ess,
    alpha_max_rhat  = alpha_max_rhat,
    alpha_min_ess   = alpha_min_ess
  )
}


# -------------------------
#' Save a fitted model as a date-stamped RDS file.
#' @param model       The fitted EMC2 model object.
#' @param name        Model name (non-date portion of the filename).
#' @param dir_path    Output directory; created recursively if absent.
#' @param date_prefix Optional 6-char YYMMDD string. Defaults to today. Pin this
#'   at the start of long-running calls so midnight crossings don't split saves
#'   into two filenames.
#' @return Full path to the saved file (invisibly usable for hook callbacks).
save_model <- function(model, name, dir_path, date_prefix = NULL) {
  if (!check_valid_string(name))     stop(sprintf("Invalid model name: %s", name))
  if (!check_valid_string(dir_path)) stop(sprintf("Invalid directory path: %s", dir_path))
  if (!dir.exists(dir_path)) dir.create(dir_path, recursive = TRUE)
  if (is.null(date_prefix)) date_prefix <- format(Sys.Date(), "%y%m%d")
  full_path <- file.path(dir_path, paste0(date_prefix, "_", name, ".rds"))
  saveRDS(model, full_path)
  return(full_path)
}
