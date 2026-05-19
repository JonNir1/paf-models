.libPaths(c(file.path(Sys.getenv("USERPROFILE"), "R", "library"), .libPaths()))
library(testthat)
ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "model_fitting", "helpers", "fitting.R"))


# =============================================================================
# get_core_args
# =============================================================================

test_that("get_core_args: cores_for_chains <= n_chains for various n_chains", {
  for (n in c(1L, 3L, 8L)) {
    args <- get_core_args(n)
    expect_lte(args$cores_for_chains, n)
  }
})

test_that("get_core_args: cores_for_chains >= 1 always", {
  for (n in c(1L, 3L, 8L)) {
    args <- get_core_args(n)
    expect_gte(args$cores_for_chains, 1L)
  }
})

test_that("get_core_args: cores_per_chain >= 1 always", {
  for (n in c(1L, 3L, 8L)) {
    args <- get_core_args(n)
    expect_gte(args$cores_per_chain, 1L)
  }
})

test_that("get_core_args: returns named list with correct keys", {
  args <- get_core_args(3L)
  expect_type(args, "list")
  expect_setequal(names(args), c("cores_for_chains", "cores_per_chain"))
})


# =============================================================================
# save_model
# =============================================================================

test_that("save_model: filename matches pattern YYMMDD_<name>.rds", {
  dir  <- tempdir()
  path <- save_model(list(x = 1), "mymodel", dir)
  fname <- basename(path)
  expect_match(fname, "^[0-9]{6}_mymodel\\.rds$")
})

test_that("save_model: custom date_prefix is used", {
  dir  <- tempdir()
  path <- save_model(list(x = 1), "m", dir, date_prefix = "991231")
  expect_match(basename(path), "^991231_m\\.rds$")
})

test_that("save_model: returns the full path as a string", {
  dir  <- tempdir()
  path <- save_model(list(x = 1), "m", dir)
  expect_type(path, "character")
  expect_true(file.exists(path))
})

test_that("save_model: saved object round-trips correctly via readRDS", {
  dir <- tempdir()
  obj <- list(a = 42, b = "hello")
  path <- save_model(obj, "roundtrip", dir)
  restored <- readRDS(path)
  expect_equal(restored, obj)
})

test_that("save_model: empty model name throws error", {
  expect_error(save_model(list(), "", tempdir()))
})
