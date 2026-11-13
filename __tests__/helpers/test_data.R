library(testthat)
ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "helpers", "data.R"))
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))

fixture_df <- load_fixture_raw


# =============================================================================
# filter_data
# =============================================================================

test_that("filter_data: invalid range or missing rt column throws error", {
  expect_error(filter_data(fixture_df(), min_rt = 0.8, max_rt = 0.2), "Invalid range")
  expect_error(filter_data(data.frame(is_target_repeated = FALSE)), "rt")
})

test_that("filter_data: RT bounds are inclusive and the row count matches", {
  df  <- fixture_df()
  lo  <- min(df$rt); hi <- max(df$rt)
  expect_equal(nrow(filter_data(df, min_rt = lo, max_rt = hi)), nrow(df))
  out <- filter_data(df, min_rt = 0.3, max_rt = 0.8)
  expect_equal(nrow(out), sum(df$rt >= 0.3 & df$rt <= 0.8))
})

# Both filtered columns become constant and are then dropped, so assert on the
# row counts rather than on the (absent) column.
test_that("filter_data: experiment and target-repeat filters keep the right rows", {
  df <- fixture_df()
  expect_equal(nrow(filter_data(df, experiment = 1)), sum(df$experiment == "exp_1"))
  expect_equal(nrow(filter_data(df, experiment = "exp_2")), sum(df$experiment == "exp_2"))
  expect_error(filter_data(df, experiment = 3), "Invalid experiment")
  expect_equal(nrow(filter_data(df, allow_target_repeats = FALSE)),
               sum(!as.logical(as.character(df$is_target_repeated))))
})

test_that("filter_data: constant-valued columns are dropped", {
  df <- fixture_df()
  df$constant_col <- 99L
  expect_false("constant_col" %in% names(filter_data(df)))
})


# =============================================================================
# Design closures: one table per closure, values + factor levels
# =============================================================================

test_that("StimulusAtLoc: returns the stimulus at location lR, levels T < D < E", {
  res <- StimulusAtLoc(data.frame(S = "T,D,E,E", lR = 1:4))
  expect_equal(as.character(res), c("T", "D", "E", "E"))
  expect_equal(levels(res), c("T", "D", "E"))
})

test_that("TargetAtLoc: TRUE only where the target is, levels FALSE < TRUE", {
  res <- TargetAtLoc(data.frame(S = "E,D,T,E", lR = 1:4))
  expect_equal(as.character(res), c("FALSE", "FALSE", "TRUE", "FALSE"))
  expect_equal(levels(res), c("FALSE", "TRUE"))
})

test_that("CueAtLoc: cue size at the cued location, NONE elsewhere, ordered levels", {
  df  <- data.frame(lR = 1:4, cue_location = 2, cue_size = "large")
  res <- CueAtLoc(df)
  expect_equal(as.character(res), c("NONE", "LARGE", "NONE", "NONE"))
  expect_equal(levels(res), c("NONE", "SMALL", "MEDIUM", "LARGE"))
})

test_that("PrevTargetAtLoc: TRUE at the previous target location, levels FALSE < TRUE", {
  res <- PrevTargetAtLoc(data.frame(lR = 1:4, prev_target_location = "3"))
  expect_equal(as.character(res), c("FALSE", "FALSE", "TRUE", "FALSE"))
  expect_equal(levels(res), c("FALSE", "TRUE"))
})

test_that("SearchDifficulty: classifies each display, order-insensitive, ordered levels", {
  cases <- c("T,E,E,E" = "EASY", "E,E,T,E" = "EASY", "T,D,D,D" = "DIFFICULT",
             "T,D,E,E" = "MIXED", "E,T,E,D" = "MIXED")
  res <- SearchDifficulty(data.frame(S = names(cases)))
  expect_equal(as.character(res), unname(cases))
  expect_equal(levels(res), c("EASY", "MIXED", "DIFFICULT"))
})

test_that("SearchDifficulty: malformed displays throw named errors", {
  errors <- c("T,E,E"   = "Unexpected number of stimuli",
              "D,E,E,E" = "Invalid number of Targets",
              "T,T,E,E" = "Invalid number of Targets",
              "T,D,D,E" = "Unsupported distractor combination")
  for (s in names(errors)) {
    expect_error(SearchDifficulty(data.frame(S = s)), errors[[s]], label = s)
  }
})


# =============================================================================
# Raw-CSV value parsers
# =============================================================================

test_that(".map_distractor: maps the enum codes 0-3 to U/T/D/E, vectorized", {
  expect_equal(.map_distractor(c(1L, 2L, 3L, 0L)), c("T", "D", "E", "U"))
})

test_that(".parse_reploc: oldloc/same -> TRUE, newloc/diff -> FALSE", {
  expect_equal(.parse_reploc(c("oldloc", "same", "newloc", "diff")),
               c(TRUE, TRUE, FALSE, FALSE))
})

test_that(".parse_cue_at_prev: 1/congruent -> TRUE, 0 and both incongruent spellings -> FALSE", {
  expect_equal(.parse_cue_at_prev(c("1", "congruent", "0", "incongurent", "incongruent")),
               c(TRUE, TRUE, FALSE, FALSE, FALSE))
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
