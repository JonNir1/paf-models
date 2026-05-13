.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)
ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "model_fitting", "helpers", "logging.R"))


# =============================================================================
# check_valid_string
# =============================================================================

test_that("check_valid_string: NULL returns FALSE", {
  expect_false(check_valid_string(NULL))
})

test_that("check_valid_string: NA returns FALSE", {
  expect_false(check_valid_string(NA_character_))
})

test_that("check_valid_string: empty string returns FALSE", {
  expect_false(check_valid_string(""))
})

test_that("check_valid_string: valid string returns TRUE", {
  expect_true(check_valid_string("hello"))
})

test_that("check_valid_string: length > 1 vector returns FALSE", {
  expect_false(check_valid_string(c("a", "b")))
})


# =============================================================================
# log_msg
# =============================================================================

test_that("log_msg: written message contains the msg substring", {
  f <- tempfile()
  log_msg("hello world", f)
  content <- readLines(f)
  expect_true(any(grepl("hello world", content)))
})

test_that("log_msg: second call appends; both messages present", {
  f <- tempfile()
  log_msg("first", f)
  log_msg("second", f)
  content <- paste(readLines(f), collapse = "\n")
  expect_true(grepl("first",  content))
  expect_true(grepl("second", content))
})

test_that("log_msg: console_print flag does not affect file content", {
  strip_ts <- function(lines) sub("^\\[.*?\\] :: ", "", lines)
  f1 <- tempfile(); f2 <- tempfile()
  log_msg("msg", f1, console_print = FALSE)
  log_msg("msg", f2, console_print = TRUE)
  expect_equal(strip_ts(readLines(f1)), strip_ts(readLines(f2)))
})

test_that("log_msg: invalid path throws error", {
  expect_error(log_msg("msg", ""))
  expect_error(log_msg("msg", NA_character_))
})


# =============================================================================
# log_error
# =============================================================================

test_that("log_error: file contains the error message", {
  f <- tempfile()
  err <- tryCatch(stop("test error msg"), error = function(e) e)
  log_error(err, f, context = "ctx")
  content <- paste(readLines(f), collapse = "\n")
  expect_true(grepl("test error msg", content))
})

test_that("log_error: file contains the context string", {
  f <- tempfile()
  err <- tryCatch(stop("oops"), error = function(e) e)
  log_error(err, f, context = "my_context")
  content <- paste(readLines(f), collapse = "\n")
  expect_true(grepl("my_context", content))
})

test_that("log_error: works with empty context string", {
  f <- tempfile()
  err <- tryCatch(stop("oops"), error = function(e) e)
  expect_no_error(log_error(err, f, context = ""))
})


# =============================================================================
# log_config_variables (sanity check only)
# =============================================================================

test_that("log_config_variables: file contains SESSION CONFIGURATION header", {
  f <- tempfile()
  log_config_variables(file.path(ROOT, "R", "config.R"), f)
  content <- paste(readLines(f), collapse = "\n")
  expect_true(grepl("SESSION CONFIGURATION", content))
})
