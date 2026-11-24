#' =============================================================================
#' Prior predictive check (analysis2 step 0) -- driver
#'
#' For each pt model: build it (cached), draw PP_N_DRAWS group parameter sets from
#' its PRIOR, simulate data on the real trial structure (untruncated), and
#' summarise the RT distribution, the share of RTs inside the analysis window
#' (MIN/MAX_SACCADE_CUTOFF) and the target-choice proportion per difficulty.
#' Use it to confirm the prior table before fitting (stop-and-review 0.9).
#'
#' Pre-settable R variables (before sourcing):
#'   PP_MODEL_NAMES  models to run (default: every pt_* model script; builds take
#'                   minutes each, so pass a subset to iterate)
#'   PP_N_DRAWS      prior draws per model (default 20)
#' Environment: PT_PRIOR_SD_SCALE as for the fits (see R/fit/helpers/pt_family.R); it also scopes
#'   the model set (names carry the `_sd<scale>` suffix) and so the build cache file.
#'
#' Writes (outputs/evaluation/prior_predictive/):
#'   prior_predictive.{rds,csv}   one row per model x draw (`rejected` = make_data
#'                                refused: >10% of parameters out of bounds)
#'   prior_predictive_summary.csv per-model medians over draws
#'   prior_predictive.png         figure
#'   builds/<model>.rds           cached built models (valid while newer than the model
#'                                script and build code, and built with this EMC2 version)
#'
#' Run from the repo root:  source("R/eval/prior_predictive.R")
#' =============================================================================

library(EMC2)
suppressPackageStartupMessages(library(dplyr))

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")
source_root("R/eval/helpers/plot.R")
source_root("R/eval/helpers/prior_predictive.R")
source_root("R/fit/helpers/recovery.R")     # simulate_recovery_data (-> build_model.R, data.R)

if (!exists("PP_N_DRAWS")) PP_N_DRAWS <- 20L
PP_DIR <- file.path(EVAL_DIR, "prior_predictive")

model_scripts <- list.files(MODEL_SCRIPT_DIR, pattern = "^pt_.*[.]R$", full.names = TRUE)
names(model_scripts) <- vapply(model_scripts, model_script_name, character(1))
if (!exists("PP_MODEL_NAMES")) PP_MODEL_NAMES <- names(model_scripts)
stopifnot(length(PP_MODEL_NAMES) > 0, all(PP_MODEL_NAMES %in% names(model_scripts)))


# Built model, cached per model (design() takes minutes).
.built_model <- function(name, data) {
  cache <- file.path(PP_DIR, "builds", paste0(name, ".rds"))
  code  <- c(model_scripts[[name]], file.path(CODE_DIR, "helpers", "data.R"),
             file.path(CODE_DIR, "fit", c("helpers/build_model.R", "helpers/pt_family.R", "fit_config.R")))
  key   <- list(emc2 = emc_version())
  if (eval_cache_fresh(cache, code, key)) return(readRDS(cache))
  build <- new.env()
  sys.source(model_scripts[[name]], envir = build)
  model <- build$build_model(data, n_chains = 1)
  attr(model, "cache_key") <- key
  dir.create(dirname(cache), recursive = TRUE, showWarnings = FALSE)
  saveRDS(model, cache)
  model
}

RNGkind(RNG_KIND)
window <- c(MIN_SACCADE_CUTOFF, MAX_SACCADE_CUTOFF)
rows   <- list()
obs_rt_q50 <- numeric()
for (nm in PP_MODEL_NAMES) {
  i    <- match(nm, names(model_scripts))   # position in the full family: seeds do not depend on the subset
  data <- load_model_data(model_scripts[[nm]])
  obs_rt_q50[[nm]] <- median(data$rt)
  message(sprintf("Prior predictive: %s (%d draws)", nm, PP_N_DRAWS))
  model <- .built_model(nm, data)
  prior <- model[[1]]$prior
  for (d in seq_len(PP_N_DRAWS)) {
    seed <- RNG_SEED + 1000L * i + d
    set.seed(seed)
    sim <- tryCatch(simulate_recovery_data(model, sample_prior_group_params(prior), data, seed = seed),
                    error = function(e) if (grepl("make_data\\(\\) returned FALSE", conditionMessage(e))) NULL else stop(e))
    rows[[length(rows) + 1L]] <-
      if (is.null(sim)) data.frame(model = nm, draw = d, rejected = TRUE)
      else data.frame(model = nm, draw = d, rejected = FALSE, summarise_prior_predictive(sim$data, window))
  }
}
PP_TABLE <- bind_rows(rows)
save_eval_table(PP_TABLE, "prior_predictive", dir = PP_DIR)

metrics <- setdiff(names(PP_TABLE), c("model", "draw", "rejected"))
PP_SUMMARY <- PP_TABLE %>%
  group_by(model) %>%
  summarise(n_rejected = sum(rejected), across(all_of(metrics), ~ median(.x, na.rm = TRUE)), .groups = "drop")
write.csv(PP_SUMMARY, file.path(PP_DIR, "prior_predictive_summary.csv"), row.names = FALSE)

ok   <- PP_TABLE[!PP_TABLE$rejected, ]
if (nrow(ok) == 0L) stop("Every prior draw was rejected by make_data(); nothing to plot (see prior_predictive.csv).")
long <- do.call(rbind, lapply(metrics, function(m)
  data.frame(model = ok$model, draw = ok$draw, metric = m, value = ok[[m]])))
if (length(unique(obs_rt_q50)) > 1L)
  stop("The models' data subsets differ (observed median RT per model: ",
       paste(sprintf("%s=%.3f", names(obs_rt_q50), obs_rt_q50), collapse = ", "), "); no single reference line.")
reference <- c(rt_q50 = obs_rt_q50[[1]], prop_in_window = 1)   # observed (already inside the window)
save_ggplot_png(plot_prior_predictive(long, reference), file.path(PP_DIR, "prior_predictive.png"),
                width = 12, height = 8)

print(PP_SUMMARY)
