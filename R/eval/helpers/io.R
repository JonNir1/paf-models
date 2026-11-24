#' =========================
#' Evaluation I/O Helpers
#' =========================
#' Small cross-cutting helpers shared by the evaluation drivers
#' (`R/eval/convergence.R`, `R/eval/goodness_of_fit.R`, ...):
#'   - latest_dated_file(): newest `YYMMDD_*` file matching a regex in a dir
#'   - model_rds_pattern(): exact-name regex for a model's fit files
#'   - model_name_from_rds(): bare model name from a fit file name
#'   - recovery_stem()    : the single naming rule of recovery fit files (generating x fitting model)
#'   - latest_model_path(): path of a model's latest fit, or stop()
#'   - load_model()       : load the latest-dated .rds for a model name from a dir
#'   - save_eval_table()  : write a data frame as paired .rds + .csv under EVAL_DIR
#'   - newer_than_inputs(): mtime freshness check for cached eval tables
#'   - eval_cache_fresh() : mtime check AND stored cache-key match
#'
#' Source chain: io.R -> utils.R (check_valid_string lives in utils.R).
#' EVAL_DIR is expected to be in scope (provided by R/config.R via the caller).

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))


#' Newest file in `dir` matching a regex, judged by its `YYMMDD_` name prefix.
#'
#' @param dir     Directory to search.
#' @param pattern Regex applied to base file names.
#' @return The file's path, or NA_character_ if nothing matches. Stops if
#'   several files share the latest date prefix.
latest_dated_file <- function(dir, pattern) {
  files <- list.files(dir, pattern = pattern, full.names = TRUE)
  if (length(files) == 0L) return(NA_character_)
  dates  <- as.Date(sub("_.*", "", basename(files)), format = "%y%m%d")
  latest <- files[dates == max(dates, na.rm = TRUE) & !is.na(dates)]
  if (length(latest) > 1L)
    stop(sprintf("Ambiguous latest file: %s share the latest date prefix.",
                 paste(sort(basename(latest), method = "radix"), collapse = ", ")))
  latest
}


#' Regex matching exactly one model's `YYMMDD_<name>[_extended].rds` files.
#'
#' @param model_name Bare model name, matched literally.
#' @return A single regex string.
model_rds_pattern <- function(model_name) {
  sprintf("^[0-9]{6}_%s(_extended)?\\.rds$", regex_escape(model_name))
}


#' `x` with every regex metacharacter escaped, so it matches literally.
regex_escape <- function(x) gsub("([.|()\\\\^{}+$*?\\[\\]])", "\\\\\\1", x, perl = TRUE)


#' Bare model name from a `YYMMDD_<name>[_extended].rds` path. Vectorised.
#'
#' @param path Character vector of file names or paths.
#' @return Character vector of model names.
model_name_from_rds <- function(path) {
  name <- sub("^[0-9]{6}_", "", tools::file_path_sans_ext(basename(path)))
  sub("(_extended)+$", "", name)
}


#' Base name (no `YYMMDD_` prefix, no extension) of one recovery fit's files.
#'
#' `<gen>_recovery_sim<N>[_fit_<fit>][<suffix>]`: the `_fit_<fit>` part appears
#' only when the simulated data were refit with a model other than the
#' generating one (model recovery), so same-model names are unchanged and a
#' cross-model fit never clobbers (or is mistaken for) a same-model one.
#'
#' @param gen_model  Generating model name (the fit the data were simulated from).
#' @param sim_index  Simulation index.
#' @param fit_model  Model refit on the simulated data (default: `gen_model`).
#' @param suffix     Optional run suffix (e.g. "_smoke").
#' @return A single string.
recovery_stem <- function(gen_model, sim_index, fit_model = gen_model, suffix = "") {
  sprintf("%s_recovery_sim%d%s%s", gen_model, sim_index,
          if (identical(fit_model, gen_model)) "" else paste0("_fit_", fit_model), suffix)
}


#' Path of the latest-dated fit of a model, or stop().
#'
#' @param model_name Bare model name, e.g. "mymodel".
#' @param dir_path   Directory to search.
#' @return Path to the latest `YYMMDD_<model_name>[_extended].rds`.
latest_model_path <- function(model_name, dir_path) {
  path <- latest_dated_file(dir_path, model_rds_pattern(model_name))
  if (is.na(path)) stop(sprintf("No version of %s found in: %s", model_name, dir_path))
  path
}


#' Load the latest-dated version of a model from a directory, or stop().
#'
#' File names are expected as `YYMMDD_<model_name>[_extended].rds`. The name is
#' matched exactly and the most recent date prefix wins.
#'
#' @param model_name Bare model name, e.g. "mymodel".
#' @param dir_path   Directory to search.
#' @return The deserialised EMC2 model object.
load_model <- function(model_name, dir_path) {
  if (!check_valid_string(model_name)) stop(sprintf("Invalid model name: %s", model_name))
  if (!check_valid_string(dir_path))   stop(sprintf("Invalid directory path: %s", dir_path))
  if (!dir.exists(dir_path))           stop(sprintf("Directory not found: %s", dir_path))

  latest_file <- latest_model_path(model_name, dir_path)
  message(sprintf("Loading latest version of %s: %s", model_name, basename(latest_file)))
  readRDS(latest_file)
}


#' Write a data frame as paired <stem>.rds + <stem>.csv under `dir`.
#'
#' @param df   Data frame to persist.
#' @param stem File stem (no extension), e.g. "convergence".
#' @param dir  Output directory (defaults to EVAL_DIR from config.R).
#' @param cache_key Optional; stored as attribute "cache_key" on the saved .rds
#'   (see eval_cache_fresh()).
#' @return Invisibly, the .rds path.
save_eval_table <- function(df, stem, dir = EVAL_DIR, cache_key = NULL) {
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE)
  if (!is.null(cache_key)) attr(df, "cache_key") <- cache_key
  rds_path <- file.path(dir, paste0(stem, ".rds"))
  csv_path <- file.path(dir, paste0(stem, ".csv"))
  saveRDS(df, rds_path)
  utils::write.csv(df, csv_path, row.names = FALSE)
  message(sprintf("Saved %s.{rds,csv} to %s/", stem, dir))
  invisible(rds_path)
}


#' Is the cached table at `cache_path` newer than EVERY input file?
#'
#' Used to decide whether to recompute an eval table. Returns FALSE (=> recompute)
#' if the cache is missing, or if any input is missing or newer than (or equal
#' to) the cache.
#'
#' @param cache_path  Path to the cached .rds.
#' @param input_paths Character vector of input file paths (e.g. model .rds files).
#' @return Logical: TRUE if the cache is fresh and can be reused.
newer_than_inputs <- function(cache_path, input_paths) {
  if (!file.exists(cache_path)) return(FALSE)
  if (length(input_paths) == 0) return(TRUE)
  cache_mtime  <- file.info(cache_path)$mtime
  input_mtimes <- file.info(input_paths)$mtime
  isTRUE(all(cache_mtime > input_mtimes))   # a missing input (NA mtime) => recompute
}


#' Is the cached .rds table reusable: newer than its inputs AND built with the
#' same settings?
#'
#' @param cache_path  Path to the cached .rds (saved via save_eval_table(cache_key=)).
#' @param input_paths Input file paths for the mtime check.
#' @param cache_key   Current settings (model names, thresholds, EMC2 version...).
#' @return Logical: TRUE if the cache can be reused.
eval_cache_fresh <- function(cache_path, input_paths, cache_key) {
  if (!newer_than_inputs(cache_path, input_paths)) return(FALSE)
  identical(attr(readRDS(cache_path), "cache_key"), cache_key)
}
