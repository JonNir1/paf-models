#' =============================================================================
#' Data Pipeline: Loading, Filtering, and EMC2 Factor Encoding
#'
#' Entry point: load_data() reads raw experiment CSVs and returns an
#' EMC2-ready filtered tibble. Use filter_data() for custom RT cutoffs on
#' an already-loaded tibble. The closure functions below are passed to
#' EMC2::design(functions = list(...)).
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/helpers/logging.R")

library(readr)
library(tools)
library(dplyr)


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


# -------------------------
# Raw-CSV Pipeline (R-native, no Python intermediate)

# DistractorTypeEnum integer -> single-letter code.
# Single letters are required: StimulusAtLoc() parses S character-by-character
# via substr(clean_S, lR, lR), matching how Python builds S via name[0].
.map_distractor <- function(x) {
  map <- c(`0` = "U", `1` = "T", `2` = "D", `3` = "E")
  unname(map[as.character(as.integer(x))])
}

# reploc column: "oldloc"/"same" -> TRUE, "newloc"/"diff" -> FALSE
.parse_reploc <- function(x) as.character(x) %in% c("oldloc", "same")

# ReplocCue column: 1/"congruent" -> TRUE, 0/"incongurent"/"incongruent" -> FALSE
# (Python source has typo "incongurent"; handle both spellings)
.parse_cue_at_prev <- function(x) as.character(x) %in% c("1", "congruent")

# Read one raw experiment CSV and return the 15-column intermediate tibble.
# Applies per-experiment column renaming, cue_size logic, and S construction.
.read_one_experiment <- function(exp_id, data_dir) {
  path <- file.path(data_dir, sprintf("exp%d", exp_id), sprintf("Exp%d_clean.csv", exp_id))
  if (!file.exists(path)) stop(sprintf("Raw data file not found: %s", path))

  raw <- read_csv(path, show_col_types = FALSE)

  # Normalise block column (Exp1: "Block", Exp2: "block_number")
  if ("Block" %in% names(raw))        raw <- rename(raw, block = Block)
  if ("block_number" %in% names(raw)) raw <- rename(raw, block = block_number)

  # cue_size: Exp1 always "MEDIUM"; Exp2 map 1->"SMALL", 2->"LARGE"
  if (exp_id == 1) {
    if ("cue_size" %in% names(raw)) stop("Unexpected cue_size column in Experiment 1 data.")
    raw$cue_size <- "MEDIUM"
  } else {
    if (!"cue_size" %in% names(raw)) stop("Missing cue_size column in Experiment 2 data.")
    raw$cue_size <- unname(c(`1` = "SMALL", `2` = "LARGE")[as.character(as.integer(raw$cue_size))])
  }

  # S string: one letter per location (sorted 1-4), comma-separated
  dist_cols <- sort(grep("^shapes_types_vec_", names(raw), value = TRUE))
  raw$S <- apply(raw[, dist_cols, drop = FALSE], 1, function(row)
    paste(.map_distractor(as.integer(row)), collapse = ","))

  raw %>%
    rename(
      subjects             = Subject,
      trials               = Trial,
      trial_in_block       = trial_number,
      target_location      = target_location_idx,
      cue_location         = cue_location_idx,
      saccade_onset        = fixation_offset_fix1,
      saccade_location     = fixation_location_fix2,
      prev_target_location = prev_tar_loc
    ) %>%
    filter(!is.na(saccade_onset)) %>%
    mutate(
      experiment            = sprintf("exp_%d", exp_id),
      search_difficulty     = toupper(search_difficulty),
      rt                    = as.numeric(saccade_onset) / 1000.0,
      R                     = ifelse(is.na(saccade_location), 0L,
                                     as.integer(as.numeric(saccade_location))),
      is_target_repeated    = .parse_reploc(reploc),
      is_cue_at_prev_target = .parse_cue_at_prev(ReplocCue)
    ) %>%
    select(experiment, subjects, block, trial_in_block, trials,
           rt, R, S, search_difficulty, target_location, cue_location, cue_size,
           is_target_repeated, is_cue_at_prev_target, prev_target_location)
}

#' Read both raw experiment CSVs, apply all transformations, and return a
#' filtered EMC2-ready tibble.
#'
#' @param data_dir             Root data directory (must contain exp1/ and exp2/).
#' @param min_rt               Lower RT bound in seconds (inclusive). Default 0.
#' @param max_rt               Upper RT bound in seconds (inclusive). Default Inf.
#' @param allow_target_repeats If FALSE, drops repeated-target trials. Default TRUE.
#' @return Filtered tibble ready for EMC2::design().
load_data <- function(data_dir             = DATA_DIR,
                      min_rt               = 0,
                      max_rt               = Inf,
                      allow_target_repeats = TRUE) {
  if (max_rt < min_rt)
    stop(sprintf("Invalid range: max_rt (%s) cannot be lower than min_rt (%s)", max_rt, min_rt))

  data <- bind_rows(
    .read_one_experiment(1L, data_dir),
    .read_one_experiment(2L, data_dir)
  ) %>%
    arrange(experiment, subjects, trials)

  message(sprintf("Loaded %d trials from raw CSVs in: %s", nrow(data), data_dir))

  # Factor encoding
  data <- data %>%
    mutate(
      search_difficulty    = factor(search_difficulty,
                                    levels = c("EASY", "MIXED", "DIFFICULT"), ordered = TRUE),
      cue_size             = factor(cue_size,
                                    levels = c("NONE", "SMALL", "MEDIUM", "LARGE"), ordered = TRUE),
      R                    = factor(R),
      cue_location         = factor(cue_location),
      target_location      = factor(target_location),
      prev_target_location = factor(prev_target_location)
    ) %>%
    mutate(across(where(is.character), factor)) %>%
    mutate(across(where(is.logical),   factor))

  # Filtering — delegates to existing filter_data()
  filter_data(data, min_rt = min_rt, max_rt = max_rt, allow_target_repeats = allow_target_repeats)
}


# -------------------------
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
