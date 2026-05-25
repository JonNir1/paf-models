#' =============================================================================
#'                    --- Model Fitting Diagnostics ---
#' =============================================================================

library(readr)
library(tools)
library(EMC2)

source("R/config.R")
source(file.path(CODE_DIR, "model_fitting", "helpers", "diagnostics_helpers.R"))

# ------------------------------
# Helper Functions

#' load the latest version of a model from specified directory, or raise an error
load_model <- function(model_name, dir_path) {
  # input validation
  if (!check_valid_string(model_name)) stop(sprintf("Invalid model name: %s", model_name))
  if (!check_valid_string(dir_path)) stop(sprintf("Invalid directory path: %s", dir_path))
  if (!dir.exists(dir_path)) stop(sprintf("Directory not found: %s", dir_path))
  
  # find all files matching the `model_name` regardless of date prefix
  all_files <- list.files(dir_path, full.names = TRUE)
  pattern <- paste0(".*_", model_name, "(_extended)?\\.rds$")
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

MODEL_NAMES <- c("model1", "model2", "model4", "model5")
MODEL_LIST <- lapply(MODEL_NAMES, load_model, dir_path = MODELS_EXTEND_DIR)
names(MODEL_LIST) <- MODEL_NAMES


if (!dir.exists(RESULTS_DIR)) dir.create(RESULTS_DIR, recursive = TRUE)

.save_table <- function(df, stem) {
  saveRDS(df, file.path(RESULTS_DIR, paste0(stem, ".rds")))
  write_csv(df, file.path(RESULTS_DIR, paste0(stem, ".csv")))
  message(sprintf("Saved %s.{rds,csv} to %s/", stem, RESULTS_DIR))
}


# ------------------------------
# (1) Convergence Diagnostics Table

diag_stem <- "model_comparison_diagnostics"
diag_rds  <- file.path(RESULTS_DIR, paste0(diag_stem, ".rds"))
if (file.exists(diag_rds)) {
  message("Loading diagnostics table from existing file...")
  DIAG_TABLE <- readRDS(diag_rds)
} else {
  message("Creating new diagnostics table...")
  DIAG_TABLE <- create_diagnostics_table(MODEL_LIST)
  .save_table(DIAG_TABLE, diag_stem)
}


# ------------------------------
# (2) Goodness-of-Fit Table

fit_stem <- "model_comparison_fit"
fit_rds  <- file.path(RESULTS_DIR, paste0(fit_stem, ".rds"))
if (file.exists(fit_rds)) {
  message("Loading GoF table from existing file...")
  FIT_TABLE <- readRDS(fit_rds)
} else {
  message("Creating new GoF table...")
  FIT_TABLE <- create_goodness_of_fit_table(
    MODEL_LIST,
    calc_bayes_factors = FALSE,
    verbose = FALSE
  )
  .save_table(FIT_TABLE, fit_stem)
}

