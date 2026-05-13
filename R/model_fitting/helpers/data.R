#' =============================================================================
#' Data Pipeline: Loading, Filtering, and EMC2 Factor Encoding
#'
#' Transforms raw experimental CSVs into an EMC2-ready design matrix.
#' Covers the full pipeline from file I/O and RT-based exclusions through
#' ordered-factor encoding of the four experimental dimensions (stimulus
#' identity, cue presence/size, previous-target location, search difficulty)
#' that EMC2's design() calls as closure functions.
#' =============================================================================

local({
  root <- Sys.getenv("PAF_REPO_ROOT", unset = "")
  if (nzchar(root)) source(file.path(root, "R", "model_fitting", "helpers", "logging.R"))
  else              source("R/model_fitting/helpers/logging.R")
})

library(readr)
library(tools)
library(dplyr)


# -------------------------
# Loading and Filtering

#' Read the EMC2 design-matrix CSV and enforce ordered factors on key columns.
#' @param path Path to CSV (relative paths resolved from getwd() = repo root).
#' @return A tibble with search_difficulty and cue_size as ordered factors.
load_safe_csv <- function(path) {
  if (!check_valid_string(path)) stop(sprintf("Invalid Path: %s", path))

  full_path <- normalizePath(path, winslash = "/", mustWork = FALSE)

  if (!file.exists(full_path)) {
    stop(sprintf("File not found at path: %s", full_path))
  }
  if (tolower(file_ext(full_path)) != "csv") {
    stop(sprintf("Invalid file format. Expected .csv, got: %s", full_path))
  }

  message(sprintf("Loading data from: %s", full_path))
  data <- read_csv(full_path, show_col_types = FALSE)

  data <- data %>% mutate(
    search_difficulty    = factor(search_difficulty, levels = c("EASY", "MIXED", "DIFFICULT"), ordered = TRUE),
    cue_size             = factor(cue_size,           levels = c("NONE", "SMALL", "MEDIUM", "LARGE"), ordered = TRUE),
    R                    = factor(R),
    cue_location         = factor(cue_location),
    target_location      = factor(target_location),
    prev_target_location = factor(prev_target_location)
  )
  data <- data %>%
    mutate(across(where(is.character), factor)) %>%
    mutate(across(where(is.logical),   factor))
  return(data)
}


#' Apply RT cutoffs and optional trial-level exclusions.
#' @param data               A data frame / tibble.
#' @param experiment         1, 2, "exp_1", or "exp_2". NULL keeps all. Default NULL.
#' @param min_rt             Lower RT bound (inclusive). Default 0.
#' @param max_rt             Upper RT bound (inclusive). Default Inf.
#' @param allow_target_repeats If FALSE, drops repeated-target trials. Default TRUE.
#' @return Filtered tibble with constant-valued columns dropped.
filter_data <- function(data,
                        experiment           = NULL,
                        min_rt               = 0,
                        max_rt               = Inf,
                        allow_target_repeats = TRUE) {
  required_cols <- c("rt", "is_target_repeated")
  if (!is.null(experiment)) required_cols <- c(required_cols, "experiment")
  missing_cols <- setdiff(required_cols, names(data))
  if (length(missing_cols) > 0) {
    stop(sprintf("Missing required columns: %s", paste(missing_cols, collapse = ", ")))
  }
  if (max_rt < min_rt) {
    stop(sprintf("Invalid range: max_rt (%s) cannot be lower than min_rt (%s)", max_rt, min_rt))
  }

  data_filtered <- data %>% filter(rt >= min_rt, rt <= max_rt)

  if (!is.null(experiment)) {
    target_exp <- switch(
      as.character(experiment),
      "1"     = "exp_1",
      "exp_1" = "exp_1",
      "2"     = "exp_2",
      "exp_2" = "exp_2",
      stop(sprintf("Invalid experiment argument: %s. Use 1, 2, 'exp_1', or 'exp_2'.", experiment))
    )
    data_filtered <- data_filtered %>% filter(experiment == target_exp)
  }

  if (!allow_target_repeats) {
    data_filtered <- data_filtered %>% filter(is_target_repeated == FALSE)
  }

  data_filtered <- data_filtered %>% select(where(~ n_distinct(.) > 1))

  message(sprintf(
    "Exclusion criteria kept %.0f rows (%.1f%%) from the original %.0f rows",
    nrow(data_filtered), 100 * nrow(data_filtered) / nrow(data), nrow(data)
  ))
  return(data_filtered)
}


# -------------------------
# EMC2 Factor Closures
# These functions are passed to EMC2::design(functions = list(...)) and are
# called once per row of the data to derive accumulator-level covariates.

#' Ordinal factor "T" < "D" < "E": stimulus presented at accumulator location lR.
StimulusAtLoc <- function(df) {
  clean_S <- gsub(",", "", as.character(df$S))
  loc_idx <- as.numeric(df$lR)
  res <- substr(clean_S, loc_idx, loc_idx)
  factor(res, levels = c("T", "D", "E"))
}


#' Ordinal factor "NONE" < "SMALL" < "MEDIUM" < "LARGE": cue size at location lR,
#' or "NONE" when the cue was shown elsewhere.
CueAtLoc <- function(df) {
  res <- ifelse(
    df$lR == df$cue_location,
    toupper(as.character(df$cue_size)),
    "NONE"
  )
  factor(res, levels = c("NONE", "SMALL", "MEDIUM", "LARGE"))
}


#' Boolean factor "FALSE" < "TRUE": whether the previous target was at location lR.
PrevTargetAtLoc <- function(df) {
  res <- df$lR == as.numeric(df$prev_target_location)
  factor(res, levels = c("FALSE", "TRUE"))
}


#' Ordinal factor "EASY" < "MIXED" < "DIFFICULT": derived from the stimulus string S
#' (T=target, D=distractor, E=easy-distractor; 4 stimuli per display).
SearchDifficulty <- function(df) {
  classify_string <- function(s) {
    elements <- trimws(unlist(strsplit(s, ",")))
    counts   <- table(factor(elements, levels = c("T", "D", "E")))
    n_T <- counts["T"]; n_D <- counts["D"]; n_E <- counts["E"]
    if (n_T + n_D + n_E != 4) stop(paste("Unexpected number of stimuli in string:", s))
    if (n_T != 1)             stop(paste("Invalid number of Targets (T) in string:", s))
    if      (n_E == 3)             return("EASY")
    else if (n_D == 3)             return("DIFFICULT")
    else if (n_D == 1 && n_E == 2) return("MIXED")
    else if (n_D == 2 && n_E == 1) stop(paste("Unsupported distractor combination (2D, 1E):", s))
    else                           stop(paste("String does not match any difficulty criteria:", s))
  }
  results <- vapply(as.character(df$S), classify_string, character(1), USE.NAMES = FALSE)
  factor(results, levels = c("EASY", "MIXED", "DIFFICULT"))
}
