#' =============================================================================
#'                    --- Model Comparison Pipeline ---
#' =============================================================================

library(readr)
library(tools)
library(EMC2)

source("R/config.R")
source(file.path(CODE_DIR, "analysis", "diagnostics_helpers.R"))

LOG_FILE <- file.path(MODELS_INITIAL_DIR, "log.txt")


# ------------------------------
# Helper Functions

#' helper function to make sure input string are valid
check_valid_string <- function(s) {
  !is.null(s) && length(s) == 1 && !is.na(s) && nzchar(s)
}


#' load the latest version of a model from specified directory, or raise an error
load_model <- function(model_name, dir_path) {
  # input validation
  if (!check_valid_string(model_name)) stop(sprintf("Invalid model name: %s", model_name))
  if (!check_valid_string(dir_path)) stop(sprintf("Invalid directory path: %s", dir_path))
  if (!dir.exists(dir_path)) stop(sprintf("Directory not found: %s", dir_path))
  
  # find all files matching the `model_name` regardless of date prefix
  all_files <- list.files(dir_path, full.names = TRUE)
  pattern <- paste0(".*_", model_name, "\\.rds$")
  matches <- all_files[grepl(pattern, basename(all_files))]
  if (length(matches) == 0) {
    stop(sprintf("No version of %s found in: %s", model_name, dir_path))
  }
  
  # extract the date from file names
  # file names should be in format `YYMMDD_model<X>.rds` where <X> is 1,2,...
  file_names <- basename(matches)
  date_strings <- sub("_.*", "", file_names)
  dates <- as.Date(date_strings, format="%y%m%d")
  
  # take the latest model
  latest_idx <- which.max(dates)
  latest_file <- matches[latest_idx]
  message(sprintf(
    "Loading latest version of %s: %s", model_name, basename(latest_file)
  ))
  return(readRDS(latest_file))
}


# ------------------------------
# Load models

MODEL_NAMES <- c("model1", "model2", "model3", "model4", "model5")
MODEL_LIST <- lapply(MODEL_NAMES, load_model, dir_path = MODELS_EXTEND_DIR)
names(MODEL_LIST) <- MODEL_NAMES


# ------------------------------
# (1) Convergence Diagnostics Table

diag_file <- file.path(RESULTS_DIR, "model_comparison_diagnostics.rds")
if (file.exists(diag_file)) {
  message("Loading diagnostics table from existing file...")
  DIAG_TABLE <- readRDS(diag_file)
} else {
  message("Creating new diagnostics table...")
  # Call the helper from diagnostics_helpers.R
  DIAG_TABLE <- create_diagnostics_table(MODEL_LIST, LOG_FILE) 
  # store to dist
  if (!dir.exists(RESULTS_DIR)) dir.create(RESULTS_DIR, recursive = TRUE)
  saveRDS(DIAG_TABLE, diag_file)
  message(sprintf("Diagnostics table saved to: %s", diag_file))
}


# ------------------------------
# (2) Goodness-of-Fit Table

fit_file <- file.path(RESULTS_DIR, "model_comparison_fit.rds")
if (!file.exists(fit_file)) {
  FIT_TABLE <- create_goodness_of_fit_table(
    MODEL_LIST, 
    LOG_FILE, 
    calc_bayes_factors = FALSE, 
    verbose = FALSE
  )
  saveRDS(FIT_TABLE, fit_file)
} else {
  FIT_TABLE <- readRDS(fit_file)
}

