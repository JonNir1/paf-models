#' =============================================================================
#' PrevTarget-locus model family (analysis2): 2^3 over PrevTargetAtLoc on {v, A, B}.
#'
#' Eight models pt_{null,v,A,B,vA,vB,AB,vAB}, one thin script each in R/fit/.
#' The base model is
#'   v ~ TargetAtLoc * SearchDifficulty, sv ~ TargetAtLoc, B ~ 1, A ~ 1, t0 ~ 1
#' (sv = log(1) constant via CONSTANTS) and `pt_on` adds PrevTargetAtLoc to the
#' named parameters: v gets the full 3-way TargetAtLoc * SearchDifficulty *
#' PrevTargetAtLoc, B and A get `~ PrevTargetAtLoc`.
#'
#' Priors: all analysis2 priors are defined below (log scale for A, B, sv, t0):
#' the intercepts (PT_INTERCEPT_MU/SD, passed via extra_mu/extra_sd so they
#' override the generic fit_config.R intercepts) and the effects
#' (PT_PRIOR_MU/PT_PRIOR_SD). Every SD is half of the first-draft table (set at
#' the step 0.9 prior check); means and SD ratios are unchanged. The hierarchical
#' variance prior stays at the EMC2 default.
#'
#' Prior sensitivity (BF): set the environment variable PT_PRIOR_SD_SCALE (e.g.
#' 0.5 or 2) BEFORE R starts; it multiplies the EFFECT SDs only, never the
#' intercepts (sv_TargetAtLocTRUE, the shared nuisance effect, is scaled too).
#' It must be an env var, not an R variable, because each model script derives
#' its MODEL_NAME from it without being executed (see pt_null.R). The value is
#' normalised ("1", "1.0", "" = unscaled; ".5" = "0.5"; whitespace trimmed;
#' non-numeric or <= 0 is an error) identically for the name (inline in each
#' script) and for the priors (pt_prior_sd_scale(), read at call time). A scaled
#' fit is named `<model>_sd<scale>` (e.g. pt_vAB_sd0.5), so its .rds, recovery,
#' PPC and BF files never clobber the main fits.
#'
#' Needs the SAME env var as the fit, because they find a model by its declared
#' name or rebuild it: fit_cloud.R --model-script, fit_recovery_cloud.R,
#' fit_ppc_cloud.R, R/eval/ppc.R, R/eval/recovery.R (model_unidentifiable_pattern()
#' looks the script up by name) and R/eval/prior_predictive.R. NOT needed by
#' convergence.R, goodness_of_fit.R, bayes_factors.R, model_recovery.R or the
#' run_bf.sh / fit_bf_cloud.R path: they work on fitted files and never look up
#' scripts (pass explicit MODEL_NAMES). The eval default MODEL_EXCLUDE_PATTERN
#' (eval_config.R) hides `_sd<scale>` fits from discover_model_names().
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/fit/helpers/build_model.R")


# Intercept priors (override fit_config.R's generic ones for this analysis). t0 mean: updated prior
# (step 0.9). RT t = 0 is the search-display (stimulus) onset, which is also the accumulation onset.
PT_INTERCEPT_MU <- c(v = 2, B = log(1), A = log(0.5), t0 = log(0.150))
PT_INTERCEPT_SD <- c(v = 0.5, B = 0.5,  A = 0.5,      t0 = 0.5)

# Effect priors (directional, hand-set from theory).
PT_PRIOR_MU <- c(
  v_TargetAtLocTRUE                                                 =  1,
  v_SearchDifficultyDIFFICULT                                       = -0.2,
  v_PrevTargetAtLocTRUE                                             =  0.75,
  `v_TargetAtLocTRUE:SearchDifficultyDIFFICULT`                     = -0.1,
  `v_TargetAtLocTRUE:PrevTargetAtLocTRUE`                           =  0,
  `v_SearchDifficultyDIFFICULT:PrevTargetAtLocTRUE`                 =  0,
  `v_TargetAtLocTRUE:SearchDifficultyDIFFICULT:PrevTargetAtLocTRUE` =  0,
  sv_TargetAtLocTRUE                                                = log(1),
  B_PrevTargetAtLocTRUE                                             = log(0.9),
  A_PrevTargetAtLocTRUE                                             = log(0.9)
)
PT_PRIOR_SD <- c(
  v_TargetAtLocTRUE                                                 = 0.5,
  v_SearchDifficultyDIFFICULT                                       = 0.5,
  v_PrevTargetAtLocTRUE                                             = 0.5,
  `v_TargetAtLocTRUE:SearchDifficultyDIFFICULT`                     = 0.25,
  `v_TargetAtLocTRUE:PrevTargetAtLocTRUE`                           = 0.25,
  `v_SearchDifficultyDIFFICULT:PrevTargetAtLocTRUE`                 = 0.25,
  `v_TargetAtLocTRUE:SearchDifficultyDIFFICULT:PrevTargetAtLocTRUE` = 0.25,
  sv_TargetAtLocTRUE                                                = 0.5,
  B_PrevTargetAtLocTRUE                                             = 0.5,
  A_PrevTargetAtLocTRUE                                             = 0.5
)

#' Multiplier on the effect SDs from the PT_PRIOR_SD_SCALE env var (read at call time).
#' Same normalisation as the MODEL_NAME expression of the pt_*.R scripts.
#' @return Positive finite number (1 when unset or empty).
pt_prior_sd_scale <- function() {
  raw <- trimws(Sys.getenv("PT_PRIOR_SD_SCALE", "1"))
  s   <- suppressWarnings(as.numeric(if (nzchar(raw)) raw else "1"))
  if (!is.finite(s) || s <= 0) stop("PT_PRIOR_SD_SCALE must be a positive number", call. = FALSE)
  s
}

PT_PARAMS <- c("v", "A", "B")


#' Parameter formulas of one family member.
#' @param pt_on Subset of c("v", "A", "B"): the parameters PrevTargetAtLoc enters.
#' @return Named list of formulas (v, sv, B, A).
pt_formulas <- function(pt_on = character()) {
  bad <- setdiff(pt_on, PT_PARAMS)
  if (length(bad) > 0L)
    stop(sprintf("pt_on must be a subset of {%s}; got: %s", paste(PT_PARAMS, collapse = ", "),
                 paste(bad, collapse = ", ")), call. = FALSE)
  list(
    v  = if ("v" %in% pt_on) v ~ TargetAtLoc * SearchDifficulty * PrevTargetAtLoc
         else                v ~ TargetAtLoc * SearchDifficulty,
    sv = sv ~ TargetAtLoc,
    B  = if ("B" %in% pt_on) B ~ PrevTargetAtLoc else B ~ 1,
    A  = if ("A" %in% pt_on) A ~ PrevTargetAtLoc else A ~ 1
  )
}


#' Sampled-parameter names the formulas imply (t0 included; the constant sv
#' intercept is excluded), without EMC2. Treatment contrasts on a factor grid
#' give EMC2's labels (`<par>`, `<par>_<term level>`); L2 checks this against a
#' real build.
pt_param_names <- function(pt_on = character()) {
  grid <- expand.grid(TargetAtLoc      = factor(c(FALSE, TRUE)),
                      SearchDifficulty = factor(c("EASY", "DIFFICULT"), levels = c("EASY", "DIFFICULT")),
                      PrevTargetAtLoc  = factor(c(FALSE, TRUE)))
  f <- pt_formulas(pt_on)
  names_of <- function(formula, par) {
    cols <- colnames(stats::model.matrix(stats::delete.response(stats::terms(formula)), grid))
    ifelse(cols == "(Intercept)", par, paste0(par, "_", cols))
  }
  nm <- unlist(Map(names_of, f, names(f)), use.names = FALSE)
  c(setdiff(nm, names(CONSTANTS)), "t0")
}


#' Effect priors with the SDs scaled by PT_PRIOR_SD_SCALE (intercepts untouched).
pt_effect_priors <- function(scale = pt_prior_sd_scale()) {
  list(mu = PT_PRIOR_MU, sd = PT_PRIOR_SD * scale)
}


#' Build one member of the PrevTarget-locus family.
#'
#' Fails before design() (minutes) if a sampled parameter has no prior.
#'
#' @param data     Data frame from load_model_data() (MIXED-free).
#' @param n_chains Passed to make_emc().
#' @param pt_on    Subset of c("v", "A", "B") that PrevTargetAtLoc enters.
#' @return An emc object.
build_pt_model <- function(data, n_chains, pt_on = character()) {
  f       <- pt_formulas(pt_on)
  priors  <- pt_effect_priors()
  effects <- setdiff(pt_param_names(pt_on), names(PT_INTERCEPT_MU))
  missing <- setdiff(effects, intersect(names(priors$mu), names(priors$sd)))
  if (length(missing) > 0L)
    stop(sprintf("No PT prior for parameter(s): %s", paste(missing, collapse = ", ")), call. = FALSE)

  build_lba_model(
    data       = data,
    n_chains   = n_chains,
    v_formula  = f$v,
    sv_formula = f$sv,
    B_formula  = f$B,
    A_formula  = f$A,
    extra_mu   = c(PT_INTERCEPT_MU, priors$mu[effects]),
    extra_sd   = c(PT_INTERCEPT_SD, priors$sd[effects]),
    functions  = LBA_FUNCTIONS[c("TargetAtLoc", "SearchDifficulty", "PrevTargetAtLoc")]
  )
}
