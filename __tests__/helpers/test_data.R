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

# EMC2's design() builds its grid from levels(), so a level emptied by row
# filtering would seed a structural-zero (ghost) parameter.
test_that("filter_data: drops factor levels emptied by the row filter, keeping level order", {
  df <- fixture_df()
  df$search_difficulty[df$search_difficulty == "DIFFICULT"] <- "EASY"
  df$search_difficulty[df$rt > 0.5] <- "DIFFICULT"   # only in rows the filter removes
  out <- filter_data(df, max_rt = 0.5)
  expect_false("DIFFICULT" %in% as.character(out$search_difficulty))
  expect_equal(levels(out$search_difficulty), c("EASY", "MIXED"))
  expect_true(is.ordered(out$search_difficulty))
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

test_that("SearchDifficulty: drops levels absent from the data, keeping the order", {
  res <- SearchDifficulty(data.frame(S = c("T,D,D,D", "T,E,E,E")))
  expect_equal(levels(res), c("EASY", "DIFFICULT"))
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
# load_data(): end to end on tiny synthetic raw CSVs
# =============================================================================

# Minimal raw schema read by .read_one_experiment(). Distractor codes:
# 1 = T, 2 = D, 3 = E. The shapes_types_vec_* columns are written out of order
# to check that S is built from the location-sorted columns. Row 5 has no
# saccade onset and must be dropped.
raw_experiment <- function(exp_id) {
  raw <- data.frame(
    Subject              = c(1, 1, 2, 2, 2) + 10 * exp_id,
    Trial                = 1:5,
    trial_number         = c(1, 2, 1, 2, 3),
    target_location_idx  = c(1, 2, 3, 4, 1),
    cue_location_idx     = c(1, 3, 2, 4, 1),
    fixation_offset_fix1 = c(300, 450, 600, 900, NA),
    fixation_location_fix2 = c(1, 2, 4, 3, NA),
    prev_tar_loc         = c(2, 1, 4, 3, 1),
    search_difficulty    = c("easy", "difficult", "mixed", "easy", "easy"),
    reploc               = c("oldloc", "newloc", "same", "diff", "same"),
    ReplocCue            = c("1", "0", "congruent", "incongurent", "1"),
    shapes_types_vec_3   = c(3, 2, 1, 3, 3),
    shapes_types_vec_1   = c(1, 2, 3, 3, 1),
    shapes_types_vec_4   = c(3, 2, 2, 1, 3),
    shapes_types_vec_2   = c(3, 1, 3, 3, 3)
  )
  if (exp_id == 1) {
    raw$Block <- c(1, 1, 2, 2, 2)
  } else {
    raw$block_number <- c(1, 1, 2, 2, 2)
    raw$cue_size     <- c(1, 2, 1, 2, 1)
  }
  raw
}
EXPECTED_S <- c("T,E,E,E", "D,T,D,D", "E,E,T,D", "E,E,E,T")

write_raw_data <- function(exp1 = raw_experiment(1), exp2 = raw_experiment(2)) {
  dir <- tempfile("raw_data_")
  for (i in 1:2) {
    dir.create(file.path(dir, sprintf("exp%d", i)), recursive = TRUE)
    readr::write_csv(list(exp1, exp2)[[i]],
                     file.path(dir, sprintf("exp%d", i), sprintf("Exp%d_clean.csv", i)),
                     na = "")
  }
  dir
}
load_quiet <- function(dir, ...) suppressMessages(load_data(data_dir = dir, ...))

test_that("load_data: returns the 15-column trial contract of sample_data.csv", {
  out <- load_quiet(write_raw_data())
  expect_equal(names(out), names(readr::read_csv(file.path(FIXTURES_DIR, "sample_data.csv"),
                                                 n_max = 0, show_col_types = FALSE)))
  expect_equal(nrow(out), 8L)   # the NA-onset row of each experiment is dropped
  expect_equal(as.character(out$experiment), rep(c("exp_1", "exp_2"), each = 4))
})

test_that("load_data: converts ms to s, builds S from sorted locations, maps every raw field", {
  out <- load_quiet(write_raw_data())
  expect_equal(out$rt, rep(c(0.3, 0.45, 0.6, 0.9), 2))
  expect_equal(as.character(out$S), rep(EXPECTED_S, 2))
  expect_equal(as.character(out$R), rep(c("1", "2", "4", "3"), 2))
  expect_equal(as.character(out$search_difficulty), rep(c("EASY", "DIFFICULT", "MIXED", "EASY"), 2))
  expect_equal(as.character(out$cue_size), c(rep("MEDIUM", 4), "SMALL", "LARGE", "SMALL", "LARGE"))
  expect_equal(as.character(out$is_target_repeated), rep(c("TRUE", "FALSE", "TRUE", "FALSE"), 2))
  expect_equal(as.character(out$is_cue_at_prev_target), rep(c("TRUE", "FALSE", "TRUE", "FALSE"), 2))
  expect_equal(as.numeric(as.character(out$block)), rep(c(1, 1, 2, 2), 2))
  expect_equal(as.character(out$subjects), c("11", "11", "12", "12", "21", "21", "22", "22"))
})

test_that("load_data: ordered factors keep the canonical order, minus absent levels", {
  out <- load_quiet(write_raw_data())
  expect_true(is.ordered(out$search_difficulty) && is.ordered(out$cue_size))
  expect_equal(levels(out$search_difficulty), c("EASY", "MIXED", "DIFFICULT"))
  expect_equal(levels(out$cue_size), c("SMALL", "MEDIUM", "LARGE"))   # NONE never occurs
  expect_equal(levels(out$R), c("1", "2", "3", "4"))
})

test_that("load_data: difficulties keeps a case-insensitive subset and drops the others' levels", {
  out <- load_quiet(write_raw_data(), difficulties = c("easy", "DIFFICULT"))
  expect_equal(nrow(out), 6L)
  expect_equal(levels(out$search_difficulty), c("EASY", "DIFFICULT"))
  expect_error(load_quiet(write_raw_data(), difficulties = "hard"), "Invalid difficulties: HARD")
})

test_that("load_data: inconsistent raw data stops with a named error", {
  bad_difficulty <- raw_experiment(1); bad_difficulty$search_difficulty[1] <- "difficult"
  exp1_with_cue  <- raw_experiment(1); exp1_with_cue$cue_size <- 1
  exp2_no_cue    <- raw_experiment(2); exp2_no_cue$cue_size <- NULL
  no_landing     <- raw_experiment(2); no_landing$fixation_location_fix2[2] <- NA
  cases <- list(
    list(dir = write_raw_data(exp1 = bad_difficulty), pattern = "search_difficulty disagreement"),
    list(dir = write_raw_data(exp1 = exp1_with_cue),  pattern = "Unexpected cue_size column in Experiment 1"),
    list(dir = write_raw_data(exp2 = exp2_no_cue),    pattern = "Missing cue_size column in Experiment 2"),
    list(dir = write_raw_data(exp2 = no_landing),     pattern = "Experiment 2: 1 trial\\(s\\) have a saccade onset but no landing")
  )
  for (cs in cases) expect_error(load_quiet(cs$dir), cs$pattern)
})

test_that("load_data: missing data_dir or an inverted RT range throws error", {
  expect_error(load_data(data_dir = file.path(tempdir(), "no_such_dir")), "not found")
  expect_error(load_data(data_dir = tempdir(), min_rt = 0.8, max_rt = 0.2), "Invalid range")
})


# =============================================================================
# model_data_args / load_model_data (per-model data subset)
# =============================================================================

test_that("model_data_args: reads a declared list without executing the script, rejects every bad declaration", {
  dir <- withr::local_tempdir()
  put <- function(file, ...) { writeLines(c(...), file.path(dir, file)); file.path(dir, file) }
  expect_identical(model_data_args(put("none.R", "stop('executed')")), list())
  expect_identical(model_data_args(put("empty.R", "MODEL_DATA_ARGS <- list()")), list())
  expect_identical(model_data_args(put("ok.R", "stop('executed')",
                                       "MODEL_DATA_ARGS = list(difficulties = c('EASY', 'DIFFICULT'))")),
                   list(difficulties = c("EASY", "DIFFICULT")))

  bad <- list(
    reserved_min_rt  = c("MODEL_DATA_ARGS <- list(min_rt = 0)",                    "may not set min_rt"),
    reserved_many    = c("MODEL_DATA_ARGS <- list(data_dir = 'x', max_rt = 2, allow_target_repeats = FALSE)",
                         "data_dir, max_rt, allow_target_repeats"),
    unknown_arg      = c("MODEL_DATA_ARGS <- list(difficultes = 'EASY')",           "unknown load_data\\(\\) argument.*difficultes"),
    unnamed          = c("MODEL_DATA_ARGS <- list('EASY')",                         "unique, non-empty name"),
    duplicate_name   = c("MODEL_DATA_ARGS <- list(difficulties = 'EASY', difficulties = 'MIXED')", "unique, non-empty name"),
    not_a_list       = c("MODEL_DATA_ARGS <- c(difficulties = 'EASY')",             "must be a list"),
    non_self_contain = c("MODEL_DATA_ARGS <- list(difficulties = some_global)",     "MODEL_DATA_ARGS")
  )
  for (case in names(bad))
    expect_error(model_data_args(put(paste0(case, ".R"), bad[[case]][1])), bad[[case]][2], info = case)
})

test_that("load_model_data: project RT cutoffs and target-repeat rule always win, the model's declared args are added", {
  source(file.path(ROOT, "R", "config.R"))   # cutoffs the runners have in scope
  rec <- call_recorder(function(...) "loaded")
  # Same formals as load_data(): model_data_args() validates declared names against them.
  local_mocks(load_data = function(data_dir = NULL, min_rt = NULL, max_rt = NULL,
                                   allow_target_repeats = NULL, difficulties = NULL)
    rec$fn(min_rt = min_rt, max_rt = max_rt, allow_target_repeats = allow_target_repeats,
           difficulties = difficulties))
  script <- withr::local_tempfile(fileext = ".R")
  writeLines("MODEL_DATA_ARGS <- list(difficulties = c('EASY', 'DIFFICULT'))", script)

  expect_identical(suppressMessages(load_model_data(script)), "loaded")
  args <- rec$calls()[[1L]]
  expect_identical(args$min_rt, MIN_SACCADE_CUTOFF)
  expect_identical(args$max_rt, MAX_SACCADE_CUTOFF)
  expect_identical(args$allow_target_repeats, ALLOW_TARGET_REPEAT)
  expect_identical(args$difficulties, c("EASY", "DIFFICULT"))

  writeLines("MODEL_NAME <- 'plain'", script)
  load_model_data(script)
  expect_null(rec$calls()[[2L]]$difficulties)
})

test_that("every runner loads model data through load_model_data(), never load_data() directly", {
  runners <- file.path(ROOT, "R", c("fit/fit_cloud.R", "fit/fit_recovery_cloud.R",
                                    "fit/fit_ppc_cloud.R", "eval/ppc.R"))
  for (path in runners) {
    code <- grep("^\\s*#", readLines(path), value = TRUE, invert = TRUE)
    expect_true(any(grepl("load_model_data\\(", code)), info = path)
    expect_false(any(grepl("\\bload_data\\(", code)), info = path)
  }
})
