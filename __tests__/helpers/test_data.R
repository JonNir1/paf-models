.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)
ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "helpers", "data.R"))

FIXTURE <- file.path(ROOT, "__tests__", "fixtures", "sample_data.csv")

# Helper: read the fixture CSV and apply EMC2 factor encoding (replaces old load_safe_csv).
fixture_df <- function() {
  readr::read_csv(FIXTURE, show_col_types = FALSE) %>%
    mutate(
      search_difficulty    = factor(search_difficulty, levels=c("EASY","MIXED","DIFFICULT"), ordered=TRUE),
      cue_size             = factor(cue_size, levels=c("NONE","SMALL","MEDIUM","LARGE"), ordered=TRUE),
      R=factor(R), cue_location=factor(cue_location),
      target_location=factor(target_location), prev_target_location=factor(prev_target_location)
    ) %>%
    mutate(across(where(is.character), factor), across(where(is.logical), factor))
}


# =============================================================================
# filter_data
# =============================================================================

test_that("filter_data: max_rt < min_rt throws error", {
  expect_error(filter_data(fixture_df(), min_rt = 0.8, max_rt = 0.2))
})

test_that("filter_data: missing rt column throws error", {
  df <- data.frame(is_target_repeated = FALSE)
  expect_error(filter_data(df))
})

test_that("filter_data: RT boundaries are inclusive", {
  df  <- fixture_df()
  lo  <- min(df$rt); hi <- max(df$rt)
  out <- filter_data(df, min_rt = lo, max_rt = hi)
  expect_true(any(out$rt == lo))
  expect_true(any(out$rt == hi))
})

test_that("filter_data: allow_target_repeats = FALSE removes repeated-target rows", {
  out <- filter_data(fixture_df(), allow_target_repeats = FALSE)
  expect_equal(sum(as.logical(as.character(out$is_target_repeated))), 0)
})

test_that("filter_data: experiment = 1 keeps only exp_1 rows", {
  out <- filter_data(fixture_df(), experiment = 1)
  expect_true(all(as.character(out$experiment) == "exp_1"))
})

test_that("filter_data: constant-valued columns are dropped", {
  df <- fixture_df()
  # artificially introduce a constant column
  df$constant_col <- 99L
  out <- filter_data(df)
  expect_false("constant_col" %in% names(out))
})

test_that("filter_data: returned row count is correct", {
  df  <- fixture_df()
  out <- filter_data(df, min_rt = 0.3, max_rt = 0.8)
  expect_equal(nrow(out), sum(df$rt >= 0.3 & df$rt <= 0.8))
})


# =============================================================================
# StimulusAtLoc
# =============================================================================

make_stim_df <- function(S_str, lR_val) {
  data.frame(S = S_str, lR = lR_val, stringsAsFactors = FALSE)
}

test_that("StimulusAtLoc: lR=1 on 'T,D,E,E' returns 'T'", {
  df  <- make_stim_df("T,D,E,E", 1)
  res <- StimulusAtLoc(df)
  expect_equal(as.character(res), "T")
})

test_that("StimulusAtLoc: lR=2 on 'T,D,E,E' returns 'D'", {
  df  <- make_stim_df("T,D,E,E", 2)
  res <- StimulusAtLoc(df)
  expect_equal(as.character(res), "D")
})

test_that("StimulusAtLoc: lR=3 on 'T,D,E,E' returns 'E'", {
  df  <- make_stim_df("T,D,E,E", 3)
  res <- StimulusAtLoc(df)
  expect_equal(as.character(res), "E")
})

test_that("StimulusAtLoc: factor levels are exactly T < D < E", {
  df  <- make_stim_df(c("T,D,E,E", "E,T,D,E"), c(1, 2))
  res <- StimulusAtLoc(df)
  expect_equal(levels(res), c("T", "D", "E"))
})


# =============================================================================
# CueAtLoc
# =============================================================================

make_cue_df <- function(lR, cue_location, cue_size) {
  data.frame(lR = lR, cue_location = cue_location, cue_size = cue_size,
             stringsAsFactors = FALSE)
}

test_that("CueAtLoc: lR == cue_location returns cue_size value", {
  df  <- make_cue_df(2, 2, "LARGE")
  res <- CueAtLoc(df)
  expect_equal(as.character(res), "LARGE")
})

test_that("CueAtLoc: lR != cue_location returns 'NONE'", {
  df  <- make_cue_df(3, 1, "SMALL")
  res <- CueAtLoc(df)
  expect_equal(as.character(res), "NONE")
})

test_that("CueAtLoc: factor levels are NONE < SMALL < MEDIUM < LARGE", {
  df  <- make_cue_df(c(1, 2, 3, 4), c(1, 2, 3, 4), c("NONE", "SMALL", "MEDIUM", "LARGE"))
  res <- CueAtLoc(df)
  expect_equal(levels(res), c("NONE", "SMALL", "MEDIUM", "LARGE"))
})


# =============================================================================
# PrevTargetAtLoc
# =============================================================================

make_prev_df <- function(lR, prev_target_location) {
  data.frame(lR = lR, prev_target_location = prev_target_location,
             stringsAsFactors = FALSE)
}

test_that("PrevTargetAtLoc: lR == prev_target_location returns TRUE", {
  df  <- make_prev_df(3, 3)
  res <- PrevTargetAtLoc(df)
  expect_equal(as.character(res), "TRUE")
})

test_that("PrevTargetAtLoc: lR != prev_target_location returns FALSE", {
  df  <- make_prev_df(2, 4)
  res <- PrevTargetAtLoc(df)
  expect_equal(as.character(res), "FALSE")
})

test_that("PrevTargetAtLoc: factor levels are FALSE < TRUE", {
  df  <- make_prev_df(c(1, 2), c(1, 3))
  res <- PrevTargetAtLoc(df)
  expect_equal(levels(res), c("FALSE", "TRUE"))
})


# =============================================================================
# SearchDifficulty
# =============================================================================

make_search_df <- function(S_vec) data.frame(S = S_vec, stringsAsFactors = FALSE)

test_that("SearchDifficulty: T,E,E,E -> EASY", {
  res <- SearchDifficulty(make_search_df("T,E,E,E"))
  expect_equal(as.character(res), "EASY")
})

test_that("SearchDifficulty: T,D,D,D -> DIFFICULT", {
  res <- SearchDifficulty(make_search_df("T,D,D,D"))
  expect_equal(as.character(res), "DIFFICULT")
})

test_that("SearchDifficulty: T,D,E,E -> MIXED", {
  res <- SearchDifficulty(make_search_df("T,D,E,E"))
  expect_equal(as.character(res), "MIXED")
})

test_that("SearchDifficulty: wrong total count throws error", {
  expect_error(SearchDifficulty(make_search_df("T,E,E")))
})

test_that("SearchDifficulty: unsupported 2D+1E combination throws error", {
  expect_error(SearchDifficulty(make_search_df("T,D,D,E")))
})

test_that("SearchDifficulty: factor levels are EASY < MIXED < DIFFICULT", {
  df  <- make_search_df(c("T,E,E,E", "T,D,E,E", "T,D,D,D"))
  res <- SearchDifficulty(df)
  expect_equal(levels(res), c("EASY", "MIXED", "DIFFICULT"))
})


# =============================================================================
# .map_distractor
# =============================================================================

test_that(".map_distractor: 1 -> T", {
  expect_equal(.map_distractor(1L), "T")
})

test_that(".map_distractor: 2 -> D", {
  expect_equal(.map_distractor(2L), "D")
})

test_that(".map_distractor: 3 -> E", {
  expect_equal(.map_distractor(3L), "E")
})

test_that(".map_distractor: 0 -> U", {
  expect_equal(.map_distractor(0L), "U")
})

test_that(".map_distractor: vectorized over a row", {
  expect_equal(.map_distractor(c(1L, 2L, 3L, 0L)), c("T", "D", "E", "U"))
})


# =============================================================================
# .parse_reploc
# =============================================================================

test_that(".parse_reploc: 'oldloc' -> TRUE", {
  expect_true(.parse_reploc("oldloc"))
})

test_that(".parse_reploc: 'same' -> TRUE", {
  expect_true(.parse_reploc("same"))
})

test_that(".parse_reploc: 'newloc' -> FALSE", {
  expect_false(.parse_reploc("newloc"))
})

test_that(".parse_reploc: 'diff' -> FALSE", {
  expect_false(.parse_reploc("diff"))
})


# =============================================================================
# .parse_cue_at_prev
# =============================================================================

test_that(".parse_cue_at_prev: '1' -> TRUE", {
  expect_true(.parse_cue_at_prev("1"))
})

test_that(".parse_cue_at_prev: 'congruent' -> TRUE", {
  expect_true(.parse_cue_at_prev("congruent"))
})

test_that(".parse_cue_at_prev: '0' -> FALSE", {
  expect_false(.parse_cue_at_prev("0"))
})

test_that(".parse_cue_at_prev: 'incongurent' (typo in source) -> FALSE", {
  expect_false(.parse_cue_at_prev("incongurent"))
})

test_that(".parse_cue_at_prev: 'incongruent' (correct spelling) -> FALSE", {
  expect_false(.parse_cue_at_prev("incongruent"))
})


# =============================================================================
# load_data: input validation (no real data required)
# =============================================================================

test_that("load_data: non-existent data_dir throws informative error", {
  expect_error(load_data(data_dir = file.path(tempdir(), "no_such_dir")),
               regexp = "not found")
})

test_that("load_data: max_rt < min_rt throws error", {
  expect_error(load_data(data_dir = tempdir(), min_rt = 0.8, max_rt = 0.2))
})
