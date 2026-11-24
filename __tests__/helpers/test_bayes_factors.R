#' =============================================================================
#' Level-1 tests for the Bayes-factor and model-recovery helpers (no EMC2;
#' emc_bridge_sampling() is mocked):
#'   - R/eval/helpers/bf.R             : compute_mll, read_mll, get_mll, bf_table
#'   - R/eval/helpers/model_recovery.R : select_by_mll, confusion_table
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/eval/eval_config.R")
source_root("R/eval/helpers/bf.R")
source_root("R/eval/helpers/model_recovery.R")
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))

CORES <- list(cores_for_props = 1L, cores_per_prop = 1L)

#' A fit .rds in `dir` named `<date>_<stem>.rds`.
fake_fit <- function(dir, stem = "m", date = "260101") {
  path <- file.path(dir, sprintf("%s_%s.rds", date, stem))
  saveRDS(list(), path)
  path
}

#' An MLL record as run_mll() writes it.
write_mll <- function(dir, stem, fit_file, mll = c(-10, -11), date = "260101", fit = NULL) {
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  path <- file.path(dir, sprintf("%s_%s_mll.rds", date, stem))
  saveRDS(list(model = stem, fit_file = fit_file, fit_md5 = if (!is.null(fit)) fit_md5(fit), reps = length(mll),
               mll = mll, n_split_warnings = 0L), path)
  path
}


test_that("compute_mll: forwards reps and cores, is seed-reproducible, rejects bad reps and wrong-length or non-finite estimates", {
  rec <- call_recorder(function(emc, ...) stats::rnorm(list(...)$repetitions, -100))
  local_mocks(emc_bridge_sampling = rec$fn)
  a <- compute_mll("emc", 3L, seed = 5L, cores = CORES)
  b <- compute_mll("emc", 3L, seed = 5L, cores = CORES)
  expect_length(a, 3L)
  expect_identical(a, b)
  args <- rec$calls()[[1L]]
  expect_identical(c(args$repetitions, args$cores_for_props, args$cores_per_prop), c(3L, 1L, 1L))

  for (reps in list(0L, -1L, NA_integer_, c(1L, 2L), "3"))
    expect_error(compute_mll("emc", reps, cores = CORES), "reps must be a single positive integer")
  for (bad in list(c(-1, NA), c(-1, Inf), numeric(0), c(-1, -2, -3))) {
    local_mocks(emc_bridge_sampling = function(...) bad)
    expect_error(compute_mll("emc", 2L, cores = CORES), "Bridge sampling returned")
  }
})

test_that("compute_mll: counts and muffles only the split-disagreement warning, lets others through, pins the RNG kind", {
  split_msg <- "estimates are off by 1 log point"
  local_mocks(emc_bridge_sampling = function(...) {
    warning(split_msg); warning("something else"); warning(split_msg)
    c(-1, -2)
  })
  got <- NULL
  expect_warning(got <- compute_mll("emc", 2L, cores = CORES), "something else")   # exactly the other one surfaces
  expect_identical(attr(got, "n_split_warnings"), 2L)
  expect_equal(as.numeric(got), c(-1, -2))

  local_mocks(emc_bridge_sampling = function(...) c(-1, -2))
  expect_identical(attr(compute_mll("emc", 2L, cores = CORES), "n_split_warnings"), 0L)

  old <- RNGkind()
  withr::defer(RNGkind(old[1L], old[2L], old[3L]))
  RNGkind("Mersenne-Twister")
  compute_mll("emc", 2L, cores = CORES)
  expect_identical(RNGkind()[1L], RNG_KIND)                              # seed reproducibility needs a fixed generator
})

test_that("read_mll / get_mll: latest record wins, a record of another fit file is stale, computing happens only when needed", {
  fits <- withr::local_tempdir()
  bf   <- withr::local_tempdir()
  fit  <- fake_fit(fits, "m", "260301")
  expect_null(read_mll(fit, dir = file.path(bf, "absent")))
  expect_null(read_mll(fit, dir = bf))
  # mll_status() names why a record is unusable (read_mll is its $record).
  why <- function(...) mll_status(fit, ...)$reason
  expect_match(why(dir = file.path(bf, "absent")), "no MLL directory")
  expect_match(why(dir = bf), "no MLL file")

  write_mll(bf, "m", "260101_m.rds", c(-1, -2), date = "260301")        # recorded against an older fit file
  expect_null(read_mll(fit, dir = bf))
  expect_match(why(dir = bf), "computed from fit file '260101_m\\.rds'")
  write_mll(bf, "m", "260301_m.rds", c(-5, -6), date = "260302", fit = fit)
  write_mll(bf, "m", "260301_m.rds", c(-9, -9), date = "260201", fit = fit)
  write_mll(bf, "m_extra", "260301_m_extra.rds", c(0, 0), date = "260401")   # another stem never matches
  expect_identical(read_mll(fit, dir = bf)$mll, c(-5, -6))

  # Staleness beyond the file name: too few reps, no md5, or other file content under the same name.
  expect_identical(read_mll(fit, reps = 2L, dir = bf)$mll, c(-5, -6))
  expect_null(read_mll(fit, reps = 3L, dir = bf))
  expect_match(why(reps = 3L, dir = bf), "2 repetitions, 3 required")
  expect_null(why(reps = 2L, dir = bf))
  other <- file.path(bf, "260303_m_mll.rds")
  saveRDS(list(fit_file = "260301_m.rds", reps = 2L, mll = c(-1, -1)), other)           # pre-md5 record
  expect_null(read_mll(fit, dir = bf))
  saveRDS(list(fit_file = "260301_m.rds", fit_md5 = "0000", reps = 2L, mll = c(-1, -1)), other)
  expect_null(read_mll(fit, dir = bf))                                                    # same name, refit content
  expect_match(why(dir = bf), "md5 mismatch")
  unlink(other)

  local_mocks(MODELS_BF_DIR = bf, emc_bridge_sampling = function(...) stop("must not run"))
  expect_identical(get_mll(fit, 2L)$mll, c(-5, -6))                      # cached: no bridge sampling
  expect_error(get_mll(fit, 3L), "2 repetitions, 3 required.*run_bf\\.sh")                        # needs more reps and local MLL is off by default

  rec   <- call_recorder(function(emc, ...) c(-7, -8))
  stale <- fake_fit(fits, "n", "260301")
  write_mll(bf, "n", "260101_n.rds", c(-1, -1), date = "260301")
  local_mocks(emc_bridge_sampling = rec$fn, emc_version = function() "x", ALLOW_LOCAL_MLL = TRUE)
  out <- suppressMessages(get_mll(stale, 2L))
  expect_length(rec$calls(), 1L)
  expect_identical(out$mll, c(-7, -8))
  expect_identical(out$fit_file, basename(stale))
  expect_identical(read_mll(stale, dir = bf)$mll, c(-7, -8))             # now cached
  expect_identical(out$fit_md5, fit_md5(stale))                          # run_mll fingerprints the fit
  expect_identical(out$n_split_warnings, 0L)
  expect_error(run_mll(file.path(fits, "absent.rds"), 2L, out_dir = bf), "Fit not found")
})

test_that("bf_table: log-BF vs the reference with a conservative envelope, posterior probabilities sum to 1, reference defaults to the best", {
  mll <- list(a = c(-100, -102, -101), b = c(-110, -112), c = -105)
  tab <- bf_table(mll)
  expect_identical(tab$model, c("a", "c", "b"))                          # best median first
  expect_true(all(tab$reference == "a"))
  expect_equal(tab$log_bf_median, c(0, -4, -10))                         # medians -101, -105, -111; b is 10 below a
  expect_equal(tab$log_bf_min, c(-102 - -100, -105 - -100, -112 - -100))
  expect_equal(tab$log_bf_max, c(-100 - -102, -105 - -102, -110 - -102))
  expect_equal(sum(tab$post_prob), 1)
  expect_equal(tab$post_prob[2] / tab$post_prob[1], exp(-4))
  expect_identical(tab$n_reps, c(3L, 1L, 2L))
  expect_true(is.na(tab$mll_sd[tab$model == "c"]))                       # one repetition: no sd
  expect_true(all(is.na(tab$n_split_warnings)))                          # absent unless supplied
  withw <- bf_table(mll, n_split_warnings = c(a = 0, b = 3, c = 1))
  expect_identical(withw$n_split_warnings, c(0L, 1L, 3L))                # matched by model, in table order

  by_b <- bf_table(mll, reference = "b")
  expect_equal(by_b$log_bf_median[by_b$model == "a"], 10)
  expect_equal(by_b$post_prob, tab$post_prob)                            # the reference does not change probabilities
  expect_equal(bf_table(list(solo = c(-1, -2)))$post_prob, 1)
  expect_equal(bf_table(list(x = -1e5, y = -1e5 - 800))$post_prob, c(1, 0))   # no underflow to NaN

  expect_error(bf_table(mll, reference = "zzz"), "Reference model 'zzz' has no MLL")
  expect_error(bf_table(list()), "non-empty named list")
  expect_error(bf_table(list(c(-1, -2))), "non-empty named list")
})

test_that("select_by_mll: picks the highest median per generating x sim, first candidate wins ties, incomplete or non-finite groups error", {
  models <- c("a", "b")
  df <- data.frame(generating = rep(c("a", "b"), each = 4), sim = rep(c(1, 1, 2, 2), 2),
                   fitted = rep(c("a", "b"), 4), mll_median = c(-1, -2, -3, -2, -5, -4, -9, -9))
  sel <- select_by_mll(df, models)
  expect_identical(sel$generating, c("a", "a", "b", "b"))
  expect_identical(sel$sim, c(1, 2, 1, 2))
  expect_identical(sel$selected, c("a", "b", "b", "a"))                  # last: exact tie goes to the first model
  expect_identical(sel$correct, c(TRUE, FALSE, TRUE, FALSE))
  expect_identical(select_by_mll(df[c(8:1), ], models), sel)             # row order is irrelevant
  expect_equal(sel$margin, c(1, 1, 1, 0))                                # best minus runner-up median
  expect_true(all(is.na(sel$spread)))                                    # no mll_range column

  rng <- transform(df, mll_range = c(0.1, 0.5, 0.2, 0.3, 0.1, 0.1, 0.4, 0.6))
  expect_equal(select_by_mll(rng, models)$spread, c(0.5, 0.3, 0.1, 0.6))  # larger range of the top two
  expect_equal(select_by_mll(transform(rng, mll_range = 9, mll_median = c(-1, -3, -2, -8, -5, -4, -1, -1)),
                             c("b", "a"))$margin, c(2, 6, 1, 0))         # candidate order only matters for ties

  expect_error(select_by_mll(df[-1, ], models), "generating 'a' sim 1 lacks a finite MLL")
  for (bad in list(NA, -Inf))
    expect_error(select_by_mll(transform(df, mll_median = replace(mll_median, 2, bad)), models), "lacks a finite MLL")
  expect_error(select_by_mll(rbind(df, df[1, ]), models), "lacks a finite MLL")        # duplicate candidate
  expect_error(select_by_mll(transform(df, fitted = replace(fitted, 2, "zzz")), models), "lacks a finite MLL")
  expect_error(select_by_mll(df[0, ], models), "no MLLs")
})

test_that("recovery_group_problem: NULL only when every candidate has a fit and an identical true_alpha incl. provenance", {
  prov  <- list(source_fit = "260101_g.rds", sim_seed = 1L, rt_window = c(0.23, 1), template = list(nrow = 4L, md5 = "aa"))
  alpha <- function(...) structure(matrix(1:4, 2), provenance = modifyList(prov, list(...)))
  fits  <- c(a = "fa.rds", b = "fb.rds")

  expect_null(recovery_group_problem(fits, list(a = alpha(), b = alpha())))
  expect_match(recovery_group_problem(c(a = "fa.rds", b = NA), list(a = alpha(), b = alpha())), "no recovery fit.*\\bb\\b")
  expect_match(recovery_group_problem(fits, list(a = alpha(), b = NULL)), "no recovery fit.*\\bb\\b")

  differing <- list(
    values   = structure(matrix(5:8, 2), provenance = prov),
    seed     = alpha(sim_seed = 2L),
    window   = alpha(rt_window = NULL),
    source   = alpha(source_fit = "260102_g.rds"),
    template = alpha(template = list(nrow = 4L, md5 = "bb")))
  for (case in names(differing))
    expect_match(recovery_group_problem(fits, list(a = alpha(), b = differing[[case]])),
                 "different simulated data", info = case)
})

test_that("confusion_table:every generating x selected cell incl. zeros, row proportions sum to 1, ordered by the candidate list", {
  sel <- data.frame(generating = c("a", "a", "a", "b"), selected = c("a", "a", "b", "b"))
  tab <- confusion_table(sel, c("b", "a", "c"))
  expect_identical(nrow(tab), 2L * 3L)
  expect_identical(tab$selected, rep(c("b", "a", "c"), 2))
  expect_identical(tab$n[tab$generating == "a"], c(1L, 2L, 0L))
  expect_equal(tab$prop[tab$generating == "a"], c(1, 2, 0) / 3)
  expect_equal(as.numeric(tapply(tab$prop, tab$generating, sum)), c(1, 1))
})
