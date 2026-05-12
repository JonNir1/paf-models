#' ========================
#' Fitting Helper Functions
#' ========================
#' handles the following:
#' (1) loading and filtering the raw data
#' (2) parsing raw data into EMC2 digestible data structs
#' (3) logging during the fitting process
#' (4) saving a fitted model


library(readr)
library(tools)
library(dplyr)

source("R/config.R")


# -------------------------
#' helper function to make sure input string are valid
check_valid_string <- function(s) {
  !is.null(s) && length(s) > 0 && !is.na(s) && nzchar(s)
}


# -------------------------
# Loading and Filtering data

#' load the raw data csv into a tibble (dataframe) or throw expressive errors.
#' @param path - String; path to csv file. if relative path, the it is assumed
#' to reside within the current working directory (getwd() + path)
#' @return a tibble
load_safe_csv <- function(path) {
  if (!check_valid_string(path)) stop(sprintf("Invalid Path: %s", path))
  
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
    search_difficulty = factor(search_difficulty, levels = c("EASY", "MIXED", "DIFFICULT")),
    cue_size = factor(cue_size, levels=c("NONE", "SMALL", "MEDIUM", "LARGE")),
    
    # inherit order from numeric columns:
    R=factor(R),
    cue_location = factor(cue_location),
    target_location = factor(target_location),
    prev_target_location=factor(prev_target_location)
  )
  # case remaining string/bool-typed columns as an alphabetically ordered factor
  data <- data %>%
    mutate(across(where(is.character), factor)) %>%
    mutate(across(where(is.logical), factor))
  return(data)
}


#' Filter data based on user-specified conditions
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


# -------------------------
# Parsing raw data into EMC2 factors

#' Returns an ordinal factor column with levels "T"<"D"<"E"
#' These values represent the stimulus presented at a specific location (stored in
#' column `df$lR`) based on the set of presented stimuli (stored in `df$S`)
StimulusAtLoc <- function(df) {
  clean_S <- gsub(",", "", as.character(df$S))
  loc_idx <- as.numeric(df$lR)
  res <- substr(clean_S, loc_idx, loc_idx)  # extract the character at location `loc_idx`
  res <- factor(res, levels = c("T", "D", "E"))
  return(res)
}


#' Returns an ordinal factor column with levels "NONE"<"SMALL"<"LARGE"
#' The value is extracted for each stimulus-location (stored in column `df$lR`):
#' it checks if the location was cued (stored in `df#cue_location`), and returns
#' "NONE" if it wasn't, or the size of the cue (stored in `df#cue_size`) otherwise
CueAtLoc <- function(df) {
  cue_size <- toupper(as.character(df$cue_size))
  res <- ifelse(
    df$lR == df$cue_location,
    cue_size,
    "NONE"
  )
  res <- factor(res, levels=c("NONE", "SMALL", "MEDIUM", "LARGE"))
  return(res)
}


#' Returns a boolean factor with levels "FALSE"<"TRUE"
#' The value is extracted by comparing the location of the previous target
#' (stored in `df$prev_target_location`) with the accumulator location (stored
#' in `df$lR`)
PrevTargetAtLoc <- function(df) {
  prev_loc <- as.numeric(df$prev_target_location)
  res <- df$lR == prev_loc
  res <- factor(res, levels=c("FALSE", "TRUE"))
  return(res)
}


#' Appends a column "SearchDifficulty" to the input `df`
#' SearchDifficulty is an ordinal factor column with levels "EASY"<"MIXED"<"DIFFICULT"
#' The value is determined based on the `df` column `df$S`, which should be a
#' factor-column in the input data
SearchDifficulty <- function(df) {
  
  # Helper function to process a single string
  classify_string <- function(s) {
    elements <- trimws(unlist(strsplit(s, ",")))
    counts <- table(factor(elements, levels = c("T", "D", "E")))
    n_T <- counts["T"]
    n_D <- counts["D"]
    n_E <- counts["E"]
    
    # Check for exactly 4 stimuli
    if (n_T + n_D + n_E != 4) {
      stop(paste("Unexpected number of stimuli in string:", s))
    }
    # Check for exactly one Target
    if (n_T != 1) {
      stop(paste("Invalid number of Targets (T) in string:", s))
    }
    # Categorize Difficulty Level
    if (n_E == 3) {
      return("EASY")
    } else if (n_D == 3) {
      return("DIFFICULT")
    } else if (n_D == 1 && n_E == 2) {
      return("MIXED")
    } else if (n_D == 2 && n_E == 1) {
      stop(paste("Unsupported distractor combination (2D, 1E) in string:", s))
    } else {
      stop(paste("String does not match any difficulty criteria:", s))
    }
  }
  
  # Apply the helper to every row
  s_vector <- as.character(df$S)
  results <- vapply(s_vector, classify_string, character(1), USE.NAMES = FALSE)
  results <- factor(results, levels = c("EASY", "MIXED", "DIFFICULT"))
  return(results)
}


# -------------------------
# logging

#' Dual-purpose logger - printing to console + to the log file
log_msg <- function(msg, file_path, console_print=FALSE) {
  if (!check_valid_string(file_path)) stop(sprintf("Invalid Log File Path: %s", file_path))
  timestamped_msg <- paste0("[", Sys.time(), "] :: ", msg, "\n")
  if (console_print) {
    cat(timestamped_msg)
  }
  cat(timestamped_msg, file = file_path, append = TRUE)
}


#' Loads config into a private environment and logs them
log_config_variables <- function(config_path, log_file) {
  if (!check_valid_string(config_path)) stop(sprintf("Invalid Config Path: %s", config_path))
  if (!check_valid_string(log_file)) stop(sprintf("Invalid Log File Path: %s", log_file))
  
  # Create a temporary 'box' to hold the config variables
  cnfg_env <- new.env()
  source(config_path, local = cnfg_env)
  
  # log the config variables to log_file
  log_msg("--- SESSION CONFIGURATION ---", log_file, console_print = FALSE)
  var_names <- ls(cnfg_env)
  for (v in var_names) {
    val <- get(v, envir = cnfg_env)
    val_str <- paste(val, collapse = ", ")
    log_msg(sprintf("  %-25s : %s", v, val_str), log_file, console_print = FALSE)
  }
  log_msg("------------------------------\n", log_file, console_print = FALSE)
}


#' log error with stack trace
#' @param err An error condition object (from tryCatch)
#' @param log_file Path to log file
#' @param context Optional string identifying where the error occurred (e.g., model name)
log_error <- function(err, log_file, context = "") {
  failed_call <- paste(deparse(conditionCall(err)), collapse = "\n")
  calls <- sys.calls()
  stack_trace <- paste(
    lapply(calls, function(x) paste(deparse(x), collapse = "\n")),
    collapse = "\n  -> "
  )
  err_msg <- sprintf(
    "FAILED [%s]\n  Error Message: %s\n  Immediate Call: %s\n  Full Stack Trace:\n  %s",
    context, err$message, failed_call, stack_trace
  )
  log_msg(err_msg, log_file, console_print = TRUE)
}


# -------------------------
# Asymmetric convergence diagnostics

#' Check $mu and $alpha convergence against block-specific Rhat/ESS thresholds.
#' $sigma2 and $correlation are intentionally NOT checked here - per the within-subject
#' OOD design they are inferentially irrelevant; report them descriptively post-fit.
#'
#' @param model A fitted EMC2 model object
#' @param max_rhat_mu,min_ess_mu Thresholds for the population mean ($mu) block
#' @param max_rhat_alpha,min_ess_alpha Thresholds for the subject-level ($alpha) block
#' @return A list with per-block diagnostics and an overall `converged` boolean
check_block_convergence <- function(model,
                                    max_rhat_mu, min_ess_mu,
                                    max_rhat_alpha, min_ess_alpha) {
  # Use EMC2::check() to get per-parameter Rhat (row 1) and ESS (row 2) per block.
  # Silenced via capture.output since check() prints summaries.
  capture.output(
    chk <- suppressWarnings(check(
      model, selection = c("mu", "alpha"), plot_worst = FALSE, digits = 4
    ))
  )
  # mu: single block of group-level means
  mu_rhat <- chk[["mu"]][["mu"]][1, ]
  mu_ess  <- chk[["mu"]][["mu"]][2, ]
  # alpha: one matrix per subject; pool across subjects
  alpha_rhat <- unlist(lapply(chk$alpha, function(x) x[1, ]))
  alpha_ess  <- unlist(lapply(chk$alpha, function(x) x[2, ]))

  mu_max_rhat    <- max(mu_rhat,    na.rm = TRUE)
  mu_min_ess     <- min(mu_ess,     na.rm = TRUE)
  alpha_max_rhat <- max(alpha_rhat, na.rm = TRUE)
  alpha_min_ess  <- min(alpha_ess,  na.rm = TRUE)

  mu_converged    <- mu_max_rhat < max_rhat_mu       && mu_min_ess    > min_ess_mu
  alpha_converged <- alpha_max_rhat < max_rhat_alpha && alpha_min_ess > min_ess_alpha

  return(list(
    converged       = mu_converged && alpha_converged,
    mu_converged    = mu_converged,
    alpha_converged = alpha_converged,
    mu_max_rhat     = mu_max_rhat,
    mu_min_ess      = mu_min_ess,
    alpha_max_rhat  = alpha_max_rhat,
    alpha_min_ess   = alpha_min_ess
  ))
}


# -------------------------
# saving model to RDS

#' Save model to the specified directory with a date prefix and the given name.
#' @param model The fitted EMC2 model object
#' @param name Model name (used as the non-date portion of the filename)
#' @param dir_path Output directory
#' @param date_prefix Optional 6-char YYMMDD string. Defaults to today's date if
#'   NULL. Pin this at the start of a long-running call (e.g. extend_model) so
#'   that mid-call saves don't split across two filenames when the run spans
#'   midnight.
save_model <- function(model, name, dir_path, date_prefix = NULL) {
  if (!check_valid_string(name)) stop(sprintf("Invalid model name: %s", name))
  if (!check_valid_string(dir_path)) stop(sprintf("Invalid directory path: %s", dir_path))
  if (!dir.exists(dir_path)) {
    dir.create(dir_path, recursive = TRUE)
  }
  if (is.null(date_prefix)) {
    date_prefix <- format(Sys.Date(), "%y%m%d")
  }
  file_name <- paste0(date_prefix, "_", name, ".rds")
  full_path <- file.path(dir_path, file_name)
  saveRDS(model, full_path)
  return(full_path)
}