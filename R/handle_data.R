library(readr)
library(tools)
library(dplyr)


#' load a csv into a tibble (dataframe) or throw expressive errors.
#' @param path - String; path to csv file. if relative path, the it is assumed
#' to reside within the current working directory (getwd() + path)
#' @return a tibble
load_safe_csv <- function(path) {
  
  # resolve Path (handle relative- vs absolute-path)
  # normalizePath automatically resolves relative paths starting from getwd()
  full_path <- normalizePath(path, winslash = "/", mustWork = FALSE)
  
  # verify file existence & correct extension
  if (!file.exists(full_path)) {
    stop(sprintf("File not found at path: %s", full_path))
  }
  if (tolower(file_ext(full_path)) != "csv") {
    stop(sprintf("Invalid file format. Expected .csv, got: %s", full_path))
  }
  
  # load the data
  message(sprintf("Loading data from: %s", full_path))
  data <- read_csv(full_path, show_col_types = FALSE)
  
  # parse columns as nominal/numeric
  data <- data %>% mutate(
    # apply a strict order over nominal columns:
    
    # R = factor(R, levels = c("UPPER_RIGHT", "UPPER_LEFT", "LOWER_LEFT", "LOWER_RIGHT")),
    # lR = factor(lR, levels = c("UPPER_RIGHT", "UPPER_LEFT", "LOWER_LEFT", "LOWER_RIGHT")),
    # distractor = factor(distractor, levels=c("TARGET", "EASY", "DIFFICULT")),
    search_difficulty = factor(search_difficulty, levels = c("EASY", "MIXED", "DIFFICULT")),
    cue_size = factor(cue_size, levels=c("NONE", "SMALL", "LARGE")),
    
    R=factor(R),
    cue_location = factor(cue_location),
    target_location = factor(target_location),
    prev_target_location=factor(prev_target_location)
    )
  # case remaining string-typed columns as an alphabetically ordered factor
  data <- data %>% mutate(across(where(is.character), factor))
  return(data)
}


#' Filter data based on user-specified conditions
#'
#' @param data A dataframe or tibble.
#' @param experiment = Numeric (1 or 2) or String ("exp_1" or "exp_2"). If provided,
#'  filters the dataset to keep only the specified experiment. Default NULL.
#' @param min_rt Numeric. Minimum reaction time (inclusive). Default 0.
#' @param max_rt Numeric. Maximum reaction time (inclusive). Default Inf.
#' @param allow_target_repeats Logical. If FALSE, removes repeated targets. Default TRUE.
#' @return A filtered tibble.
filter_data <- function(
    data,
    experiment = NULL,
    min_rt = 0,
    max_rt = Inf,
    allow_target_repeats = TRUE
) {
  # verify column existence
  required_cols <- c("rt", "is_target_repeated")
  if (!is.null(experiment)) {
    required_cols <- c(required_cols, "experiment")
  }
  missing_cols <- setdiff(required_cols, names(data))
  if (length(missing_cols) > 0) {
    stop(sprintf("Missing required columns: %s", paste(missing_cols, collapse = ", ")))
  }
  # validate threshold values
  if (max_rt < min_rt) {
    stop(sprintf("Invalid range: max_rt (%s) cannot be lower than min_rt (%s)", max_rt, min_rt))
  }
  
  # apply exclusion criteria
  data_filtered <- data %>%
    filter(rt >= min_rt, rt <= max_rt)
  
  if (!is.null(experiment)) {
    # normalize input: map 1 -> "exp_1", 2 -> "exp_2"
    target_exp <- switch(
      as.character(experiment),
      "1" = "exp_1",
      "exp_1" = "exp_1",
      "2" = "exp_2",
      "exp_2" = "exp_2",
      stop(sprintf("Invalid experiment argument: %s. Use 1, 2, 'exp_1', or 'exp_2'.", experiment))
    )
    data_filtered <- data_filtered %>%
      filter(experiment == target_exp)
  }
  
  if (!allow_target_repeats) {
    data_filtered <- data_filtered %>%
      filter(is_target_repeated == FALSE)
  }
  
  # drop columns with a single unique value
  data_filtered <- data_filtered %>%
    select(where(~ n_distinct(.) > 1))
  
  # return subset
  message(sprintf(
    "Exclusion criteria kept %.0f rows (%.1f%%) from the original %.0f rows",
    nrow(data_filtered), 100*nrow(data_filtered)/nrow(data), nrow(data)
    ))
  return(data_filtered)
}

