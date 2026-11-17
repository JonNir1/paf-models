library(testthat)
ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "fit", "helpers", "fitting.R"))
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))   # local_mocks()


test_that("get_core_args: chain cores are capped by n_chains and the core count, never below 1", {
  for (total in list(NA_integer_, 0L, 2L, 16L)) {
    local_mocked_bindings(detectCores = function(...) total, .package = "parallel")
    usable <- if (is.na(total) || total < 1L) 1L else total
    for (n in c(1L, 3L, 8L)) {
      args <- get_core_args(n)
      lbl  <- sprintf("total=%s, n_chains=%d", total, n)
      expect_setequal(names(args), c("cores_for_chains", "cores_per_chain"))
      expect_equal(args$cores_for_chains, min(n, usable), label = lbl)
      expect_gte(args$cores_per_chain, 1L)
    }
  }
})


test_that("save_model: writes <date>_<name>.rds that round-trips, with today or a pinned date", {
  local_mocks(emc_version = function() "9.9.9")
  dir  <- tempfile("save_model_")
  obj  <- list(a = 42, b = "hello")
  path <- save_model(obj, "mymodel", dir)
  expect_true(dir.exists(dir))
  expect_equal(basename(path), paste0(format(Sys.Date(), "%y%m%d"), "_mymodel.rds"))
  expect_equal(readRDS(path), stamp_emc2_version(obj))
  expect_identical(attr(readRDS(path), "emc2_version"), "9.9.9")
  expect_equal(basename(save_model(obj, "m", dir, date_prefix = "991231")), "991231_m.rds")
})

test_that("stamp_emc2_version / save_model: history accumulates across EMC2 versions, seeded from a legacy attribute", {
  version <- "3.4.1"
  local_mocks(emc_version = function() version)

  m <- stamp_emc2_version(list(chain = 1))
  expect_identical(attr(m, "emc2_version"), "3.4.1")
  expect_identical(attr(m, "emc2_version_history"), "3.4.1")

  expect_identical(attr(stamp_emc2_version(m), "emc2_version_history"), "3.4.1")   # same version: no duplicate

  version <- "3.5.0"
  m <- stamp_emc2_version(m)
  expect_identical(attr(m, "emc2_version"), "3.5.0")
  expect_identical(attr(m, "emc2_version_history"), c("3.4.1", "3.5.0"))

  version <- "3.4.1"                                     # back to the old version: current moves, history keeps order
  m <- stamp_emc2_version(m)
  expect_identical(attr(m, "emc2_version"), "3.4.1")
  expect_identical(attr(m, "emc2_version_history"), c("3.4.1", "3.5.0"))

  legacy <- structure(list(chain = 1), emc2_version = "3.3.0")   # saved before histories existed
  version <- "3.5.0"
  path <- save_model(legacy, "legacy", withr::local_tempdir())
  back <- readRDS(path)
  expect_identical(attr(back, "emc2_version"), "3.5.0")
  expect_identical(attr(back, "emc2_version_history"), c("3.3.0", "3.5.0"))
  expect_identical(back[[1]], 1)
})

test_that("save_model: empty name or directory throws error", {
  expect_error(save_model(list(), "", tempdir()), "Invalid model name")
  expect_error(save_model(list(), "m", ""), "Invalid directory path")
})
