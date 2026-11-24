#' =============================================================================
#' Level-1 tests for file naming and I/O (no EMC2):
#'   - R/eval/helpers/io.R : latest_dated_file, model_name_from_rds, load_model,
#'                           save_eval_table, newer_than_inputs
#'   - R/eval/eval_config.R: discover_model_names, model_colors
#'   - R/utils.R           : parse_int_arg, parse_str_arg, find_model_script
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/eval/eval_config.R")
source_root("R/fit/helpers/fitting.R")   # save_model()
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))   # local_mocks()

touch_rds <- function(dir, files) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  for (f in files) saveRDS(list(file = f), file.path(dir, f))
  dir
}


test_that("load_model: exact name, latest date wins, _extended accepted", {
  dir <- touch_rds(tempfile("models_"), c(
    "260101_model.rds", "260301_model_extended.rds", "260201_model.rds",
    "260901_test_model.rds", "261001_model2.rds", "261101_model.rds.bak"
  ))
  load <- function(name) suppressMessages(load_model(name, dir))$file
  expect_equal(load("model"), "260301_model_extended.rds")
  expect_equal(load("test_model"), "260901_test_model.rds")
  expect_equal(load("model2"), "261001_model2.rds")
  expect_error(load("mod"), "No version of mod found")
  expect_error(load("model.*"), "No version of model\\.\\* found")   # regex metachars are literal
})

test_that("load_model: invalid name, invalid or missing directory throw errors", {
  expect_error(load_model("", tempdir()), "Invalid model name")
  expect_error(load_model("m", NA_character_), "Invalid directory path")
  expect_error(load_model("m", file.path(tempdir(), "no_such_dir")), "Directory not found")
})

test_that("latest_dated_file / model_name_from_rds: NA when nothing matches; names stripped", {
  expect_identical(latest_dated_file(tempfile("empty_"), "\\.rds$"), NA_character_)
  dir <- touch_rds(tempfile("dated_"), c("260101_a.rds", "260301_a.rds", "notes.rds"))
  expect_equal(basename(latest_dated_file(dir, "\\.rds$")), "260301_a.rds")   # undated names never win

  tie <- touch_rds(tempfile("tie_"), c("260301_model.rds", "260301_model_extended.rds", "260101_model.rds"))
  expect_error(latest_dated_file(tie, "\\.rds$"), "Ambiguous latest file.*260301_model\\.rds.*260301_model_extended\\.rds")
  expect_error(suppressMessages(load_model("model", tie)), "Ambiguous latest file")   # never picks by directory order
  expect_equal(model_name_from_rds(c("260101_m.rds", "dir/260101_m_extended.rds",
                                     "260101_test_model.rds", "260101_a_b_c.rds")),
               c("m", "m", "test_model", "a_b_c"))
})

test_that("discover_model_names: unique sorted bare names; empty or missing dir gives none", {
  dir <- touch_rds(tempfile("fit_"), c("260101_zeta.rds", "260201_alpha_extended.rds",
                                       "260301_alpha.rds", "notes.rds", "log_fit_zeta.txt"))
  expect_equal(discover_model_names(dir), c("alpha", "zeta"))
  expect_identical(discover_model_names(file.path(tempdir(), "no_such_dir")), character(0))
  empty <- tempfile("fit_empty_"); dir.create(empty)
  expect_identical(discover_model_names(empty), character(0))

  # exclude regex drops matching names; NA (the default) keeps all
  expect_equal(discover_model_names(dir, exclude = "^z"), "alpha")
  expect_equal(discover_model_names(dir, exclude = NA_character_), c("alpha", "zeta"))
  expect_identical(discover_model_names(dir, exclude = "."), character(0))

  # a pre-set MODEL_NAMES is validated against ALL fits (exclude does not apply); unknown names fail clearly
  expect_silent(check_model_names(c("zeta", "alpha"), dir))
  expect_error(check_model_names(c("alpha", "nope"), dir), "no fit in.*nope")
})

test_that("eval drivers honour a pre-set MODEL_NAMES (no unconditional discovery)", {
  for (f in c("convergence", "goodness_of_fit", "bayes_factors", "recovery", "ppc", "model_recovery")) {
    src <- readLines(file.path(ROOT, "R", "eval", paste0(f, ".R")))
    expect_false(any(grepl("^MODEL_NAMES <- discover_model_names", src)), info = f)
    expect_true(any(startsWith(src, "if (!exists(\"MODEL_NAMES\")) MODEL_NAMES <- discover_model_names")), info = f)
  }
})

test_that("save_model -> discover_model_names -> load_model round-trips a model", {
  dir <- tempfile("roundtrip_")
  local_mocks(emc_version = function() "9.9.9")
  obj <- list(chains = 3, tag = "fitted")
  save_model(obj, "my_model.v2", dir)
  name <- discover_model_names(dir)
  expect_equal(name, "my_model.v2")
  loaded <- suppressMessages(load_model(name, dir))
  expect_equal(loaded[names(obj)], obj)
  expect_identical(attr(loaded, "emc2_version"), "9.9.9")
  expect_identical(attr(loaded, "emc2_version_history"), "9.9.9")
})

test_that("save_eval_table: writes matching .rds and .csv, creating the directory", {
  dir  <- file.path(tempfile("eval_"), "nested")
  df   <- data.frame(model = c("a", "b"), value = c(1.5, 2))
  path <- suppressMessages(save_eval_table(df, "convergence", dir))
  expect_equal(path, file.path(dir, "convergence.rds"))
  expect_equal(readRDS(path), df)
  expect_equal(utils::read.csv(file.path(dir, "convergence.csv")), df)
})

test_that("newer_than_inputs: missing cache, equal or older mtime -> recompute", {
  dir   <- tempfile("cache_"); dir.create(dir)
  cache <- file.path(dir, "cache.rds"); input <- file.path(dir, "input.rds")
  saveRDS(1, cache); saveRDS(1, input)
  t0 <- Sys.time()
  set_mtimes <- function(cache_t, input_t) {
    Sys.setFileTime(cache, cache_t); Sys.setFileTime(input, input_t)
  }

  expect_false(newer_than_inputs(file.path(dir, "absent.rds"), input))
  expect_true(newer_than_inputs(cache, character(0)))
  set_mtimes(t0 + 10, t0);      expect_true(newer_than_inputs(cache, input))
  set_mtimes(t0, t0);           expect_false(newer_than_inputs(cache, input))
  set_mtimes(t0, t0 + 10);      expect_false(newer_than_inputs(cache, input))
  set_mtimes(t0 + 10, t0);      expect_false(newer_than_inputs(cache, c(input, file.path(dir, "gone.rds"))))
})

test_that("eval_cache_fresh: reused only when newer than every input AND built with identical settings", {
  dir   <- withr::local_tempdir()
  input <- file.path(dir, "fit.rds"); saveRDS(1, input)
  key   <- list(models = c("a", "b"), files = c("250101_a.rds", "250102_b.rds"), thresholds = c(1.05, 500, 1.1, 400), emc2 = "3.5.0")
  cache <- function(stem, k) suppressMessages(save_eval_table(data.frame(x = 1), stem, dir, cache_key = k))
  age   <- function(path, secs) Sys.setFileTime(path, Sys.time() + secs)
  age(input, -20)

  fresh <- cache("fresh", key);  age(fresh, 0)
  expect_true(eval_cache_fresh(fresh, input, key))

  for (changed in list(modifyList(key, list(models = "a")),
                       modifyList(key, list(thresholds = c(1.1, 500, 1.1, 400))),
                       modifyList(key, list(emc2 = "3.4.1")),
                       # newest fit of "b" deleted: an older file becomes the latest
                       modifyList(key, list(files = c("250101_a.rds", "241231_b.rds"))))) {
    expect_false(eval_cache_fresh(fresh, input, changed))
  }

  nokey <- cache("nokey", NULL); age(nokey, 0)
  expect_false(eval_cache_fresh(nokey, input, key))

  stale <- cache("stale", key); age(stale, -40)
  expect_false(eval_cache_fresh(stale, input, key))
  expect_false(eval_cache_fresh(file.path(dir, "absent.rds"), input, key))
})

test_that("model_colors: one stable colour per model, recycling past the palette", {
  cols <- model_colors(paste0("m", 1:10))
  expect_equal(names(cols), paste0("m", 1:10))
  expect_match(cols, "^#[0-9a-f]{6}$")
  expect_equal(unname(cols[9:10]), unname(cols[1:2]))
  expect_equal(model_colors(c("m1", "m2")), cols[1:2])
})

test_that("parse_int_arg / parse_str_arg: value after the flag, else NULL; malformed int is NA", {
  args <- c("--model-script", "R/fit/m.R", "--max-tries", "5", "--bad", "abc", "--trailing")
  expect_identical(parse_str_arg(args, "--model-script"), "R/fit/m.R")
  expect_identical(parse_int_arg(args, "--max-tries"), 5L)
  expect_null(parse_int_arg(args, "--absent"))
  expect_null(parse_str_arg(args, "--trailing"))
  expect_warning(bad <- parse_int_arg(args, "--bad"), "NAs introduced")
  expect_identical(bad, NA_integer_)
})

test_that("find_model_script: locates by declared MODEL_NAME without executing, skips non-models, errors clearly", {
  dir <- withr::local_tempdir()
  put <- function(file, ...) writeLines(c(...), file.path(dir, file))
  put("odd_file_name.R", "stop('boom')", "MODEL_NAME <- 'alpha'")   # name differs from file; top level would fail if run
  put("beta.R", "MODEL_NAME = paste0('b', 'eta')")                  # `=` and base-R rhs
  put("runner.R", "x <- 1")                                         # no MODEL_NAME
  put("config.R", "MODEL_NAME <- some_global()")                    # rhs not self-contained
  put("vec.R", "MODEL_NAME <- c('a', 'b')")                         # not a length-1 string
  put("broken.R", "MODEL_NAME <- 'gamma'", "this is ( not R")
  expect_equal(find_model_script("alpha", dir), file.path(dir, "odd_file_name.R"))
  expect_equal(find_model_script("beta", dir), file.path(dir, "beta.R"))

  err <- expect_error(find_model_script("nope", dir), "No model script.*'nope'")
  expect_match(conditionMessage(err), "Model names found: alpha, beta[.]")
  expect_match(conditionMessage(err), "cannot be parsed.*broken[.]R")   # a broken script is never a bare "not found"

  put("alpha_copy.R", "MODEL_NAME <- 'alpha'")
  expect_error(find_model_script("alpha", dir), "more than one script.*alpha_copy[.]R, odd_file_name[.]R")
  put("twice.R", "MODEL_NAME <- 'twice'", "MODEL_NAME <- 'twice'")
  expect_error(find_model_script("beta", dir), "twice[.]R.*more than once")
  expect_error(find_model_script("alpha", file.path(dir, "absent")), "directory not found")

  # model_script_name(): the declared name of one script; anything but a top-level non-empty string errors.
  expect_identical(model_script_name(file.path(dir, "odd_file_name.R")), "alpha")
  expect_identical(model_script_name(file.path(dir, "beta.R")), "beta")
  put("empty.R", "MODEL_NAME <- ''")
  for (bad in c("runner.R", "config.R", "vec.R", "twice.R", "broken.R", "empty.R"))
    expect_error(model_script_name(file.path(dir, bad)), bad, fixed = TRUE, info = bad)
})


test_that("recovery_stem: same-model names unchanged; cross-model fits never match the same-model recovery selectors", {
  expect_identical(recovery_stem("m", 2L), "m_recovery_sim2")
  expect_identical(recovery_stem("m", 2L, "m", "_smoke"), "m_recovery_sim2_smoke")
  expect_identical(recovery_stem("m", 2L, "other"), "m_recovery_sim2_fit_other")
  expect_identical(recovery_stem("m", 2L, "other", "_smoke"), "m_recovery_sim2_fit_other_smoke")

  dir <- touch_rds(tempfile("recovery_"), c(
    "260101_m_recovery_sim1.rds", "260101_m_recovery_sim1_true_alpha.rds",
    "260901_m_recovery_sim1_fit_other.rds", "260901_m_recovery_sim1_fit_other_true_alpha.rds",
    "260901_m_recovery_sim1_extended.rds"))
  # The selectors of R/eval/recovery.R load_recovery_pair(): the newer cross-model files must not win.
  expect_match(latest_dated_file(dir, "^[0-9]{6}_m_recovery_sim1\\.rds$"), "260101_m_recovery_sim1\\.rds$")
  expect_match(latest_dated_file(dir, "^[0-9]{6}_m_recovery_sim1_true_alpha\\.rds$"), "260101_m_recovery_sim1_true_alpha")
  # Fit-file selectors ignore recovery files; the model-recovery selector finds exactly the cross-model fit.
  expect_true(is.na(latest_dated_file(dir, model_rds_pattern("m"))))
  expect_match(latest_dated_file(dir, sprintf("^[0-9]{6}_%s\\.rds$", regex_escape(recovery_stem("m", 1L, "other")))),
               "260901_m_recovery_sim1_fit_other\\.rds$")
})
