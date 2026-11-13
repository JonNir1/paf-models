library(testthat)
ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "fit", "helpers", "fitting.R"))


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
  dir  <- tempfile("save_model_")
  obj  <- list(a = 42, b = "hello")
  path <- save_model(obj, "mymodel", dir)
  expect_true(dir.exists(dir))
  expect_equal(basename(path), paste0(format(Sys.Date(), "%y%m%d"), "_mymodel.rds"))
  expect_equal(readRDS(path), obj)
  expect_equal(basename(save_model(obj, "m", dir, date_prefix = "991231")), "991231_m.rds")
})

test_that("save_model: empty name or directory throws error", {
  expect_error(save_model(list(), "", tempdir()), "Invalid model name")
  expect_error(save_model(list(), "m", ""), "Invalid directory path")
})
