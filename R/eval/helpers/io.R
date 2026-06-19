#' =========================
#' Evaluation I/O Helpers
#' =========================
#' Small cross-cutting helpers shared by the evaluation drivers
#' (`R/eval/convergence.R`, `R/eval/model_comparison.R`, ...):
#'   - load_model()       : load the latest-dated .rds for a model name from a dir
#'   - save_eval_table()  : write a data frame as paired .rds + .csv under EVAL_DIR
#'   - newer_than_inputs(): mtime freshness check for cached eval tables
#'
#' Source chain: io.R -> utils.R (check_valid_string lives in utils.R).
#' EVAL_DIR is expected to be in scope (provided by R/config.R via the caller).

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))


#' Load the latest-dated version of a model from a directory, or stop().
#'
#' File names are expected as `YYMMDD_<model_name>[_extended].rds`. The most
#' recent date prefix wins.
#'
#' @param model_name Bare model name, e.g. "mymodel".
#' @param dir_path   Directory to search.
#' @return The deserialised EMC2 model object.
load_model <- function(model_name, dir_path) {
  if (!check_valid_string(model_name)) stop(sprintf("Invalid model name: %s", model_name))
  if (!check_valid_string(dir_path))   stop(sprintf("Invalid directory path: %s", dir_path))
  if (!dir.exists(dir_path))           stop(sprintf("Directory not found: %s", dir_path))

  all_files <- list.files(dir_path, full.names = TRUE)
  pattern   <- paste0(".*_", model_name, "(_extended)?\\.rds$")
  matches   <- all_files[grepl(pattern, basename(all_files))]
  if (length(matches) == 0) {
    stop(sprintf("No version of %s found in: %s", model_name, dir_path))
  }

  date_strings <- sub("_.*", "", basename(matches))
  dates        <- as.Date(date_strings, format = "%y%m%d")
  latest_file  <- matches[which.max(dates)]
  message(sprintf("Loading latest version of %s: %s", model_name, basename(latest_file)))
  readRDS(latest_file)
}


#' Write a data frame as paired <stem>.rds + <stem>.csv under `dir`.
#'
#' @param df   Data frame to persist.
#' @param stem File stem (no extension), e.g. "convergence".
#' @param dir  Output directory (defaults to EVAL_DIR from config.R).
#' @return Invisibly, the .rds path.
save_eval_table <- function(df, stem, dir = EVAL_DIR) {
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE)
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
#' if the cache is missing or if any input is newer than (or equal to) the cache.
#'
#' @param cache_path  Path to the cached .rds.
#' @param input_paths Character vector of input file paths (e.g. model .rds files).
#' @return Logical: TRUE if the cache is fresh and can be reused.
newer_than_inputs <- function(cache_path, input_paths) {
  if (!file.exists(cache_path)) return(FALSE)
  if (length(input_paths) == 0) return(TRUE)
  cache_mtime  <- file.info(cache_path)$mtime
  input_mtimes <- file.info(input_paths)$mtime
  all(cache_mtime > input_mtimes, na.rm = FALSE)
}
