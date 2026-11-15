library(testthat)
ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "helpers", "logging.R"))

read_all <- function(f) paste(readLines(f), collapse = "\n")


test_that("check_valid_string: only a single non-empty, non-NA string is valid", {
  invalid <- list(NULL, NA_character_, "", c("a", "b"))
  for (x in invalid) expect_false(check_valid_string(x), label = deparse(x))
  expect_true(check_valid_string("hello"))
})


test_that("log_msg: appends timestamped lines; console_print only adds a stdout echo", {
  f <- tempfile()
  log_msg("first", f)
  expect_output(log_msg("second", f, console_print = TRUE), "second")
  lines <- readLines(f)
  expect_length(lines, 2L)
  expect_match(lines, "^\\[.+\\] :: ")
  expect_equal(sub("^\\[.*?\\] :: ", "", lines), c("first", "second"))
})

test_that("log_msg: invalid path throws error; NULL path logs to the console only", {
  expect_error(log_msg("msg", ""))
  expect_error(log_msg("msg", NA_character_))
  expect_output(log_msg("console only", NULL), "console only")
})


test_that("log_error: records the error message and context, also with empty context", {
  f   <- tempfile()
  err <- tryCatch(stop("test error msg"), error = function(e) e)
  expect_output(log_error(err, f, context = "my_context"), "my_context")
  expect_match(read_all(f), "FAILED \\[my_context\\].*test error msg")

  g <- tempfile()
  expect_output(log_error(err, g, context = ""), "FAILED \\[\\]")
})


test_that("log_config_variables: logs the header and every config variable", {
  f <- tempfile()
  log_config_variables(file.path(ROOT, "R", "config.R"), f)
  content <- read_all(f)
  expect_match(content, "SESSION CONFIGURATION")
  expect_match(content, "MIN_SACCADE_CUTOFF")
})
