#' =============================================================================
#' Level-1 unit tests for eval-side helpers (no EMC2 required):
#'   - add_convergence_verdict() / metric_verdict()  (R/eval/helpers/convergence.R)
#'   - get_prior_sds(), zscore_contraction(), flag_identifiable(),
#'     recovery_model_summary(), recovery_subject_rows(),
#'     recovery_subject_stats()                       (R/eval/helpers/recovery.R)
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "eval", "helpers", "convergence.R"))
source(file.path(ROOT, "R", "eval", "helpers", "recovery.R"))
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))   # local_mocks()


# =============================================================================
# add_convergence_verdict() / metric_verdict()
# =============================================================================

# Fixed thresholds for hermetic tests (mirror the R/config.R defaults).
TH <- list(rhat_mu = 1.05, ess_mu = 500, rhat_alpha = 1.10, ess_alpha = 400)

verdict_table <- function(rows) {
  tbl <- data.frame(model = "m",
                    group          = vapply(rows, `[[`, "", "group"),
                    max_rhat       = vapply(rows, `[[`, 0, "rhat"),
                    min_ess        = vapply(rows, `[[`, 0, "ess"),
                    p_rhat_gt_1.01 = vapply(rows, `[[`, 0, "p_hi"),
                    stringsAsFactors = FALSE)
  add_convergence_verdict(tbl, max_rhat_mu = TH$rhat_mu, min_ess_mu = TH$ess_mu,
                          max_rhat_alpha = TH$rhat_alpha, min_ess_alpha = TH$ess_alpha)
}
row <- function(group, rhat, ess, p_hi, verdict, why) {
  list(group = group, rhat = rhat, ess = ess, p_hi = p_hi, verdict = verdict, why = why)
}

test_that("add_convergence_verdict: block verdicts across descriptive / pass / marginal / fail", {
  rows <- list(
    row("sigma2",      1.30,  100,  60,   "descriptive", "never gated"),
    row("correlation", 1.40,  50,   80,   "descriptive", "never gated"),
    row("mu",          1.010, 1200, 5,    "pass",        "clean mu"),
    row("alpha",       1.020, 900,  6,    "pass",        "clean alpha"),
    row("mu",          1.023, 1047, 7.1,  "pass",        "real model1 mu"),
    row("mu",          1.060, 1200, 5,    "fail",        "mu Rhat > 1.05"),
    row("mu",          1.010, 480,  5,    "fail",        "mu ESS < 500"),
    row("alpha",       1.120, 900,  5,    "fail",        "alpha Rhat > 1.10"),
    row("alpha",       1.020, 390,  5,    "fail",        "alpha ESS < 400"),
    row("mu",          1.048, 1200, 5,    "marginal",    "Rhat within 0.005 of the ceiling"),
    row("mu",          1.050, 1200, 5,    "marginal",    "Rhat exactly at the ceiling is not a fail"),
    row("mu",          1.010, 500,  5,    "marginal",    "ESS exactly at the floor is not a fail"),
    row("mu",          1.010, 540,  5,    "marginal",    "ESS within 10% of 500"),
    row("mu",          1.010, 1200, 30,   "marginal",    "> 25% of Rhat > 1.01"),
    row("mu",          1.010, 1200, 25,   "pass",        "exactly 25% of Rhat > 1.01"),
    row("alpha",       1.097, 423,  14.4, "marginal",    "real model4 alpha"),
    row("alpha",       1.020, 430,  5,    "marginal",    "alpha ESS within 10% of 400"),
    row("theta",       1.000, 9999, 0,    NA_character_, "unknown group")
  )
  out <- verdict_table(rows)
  for (i in seq_along(rows)) {
    expect_identical(out$verdict[i], rows[[i]]$verdict, label = rows[[i]]$why)
  }
})

test_that("add_convergence_verdict: Rhat and ESS verdicts split; combined is the worse", {
  out <- verdict_table(list(row("mu", 1.048, 1001, 40, NA, "real model5 mu"),
                            row("alpha", 1.01, 390, 0, NA, "ESS fail only")))
  expect_equal(out$verdict_rhat, c("marginal", "pass"))
  expect_equal(out$verdict_ess,  c("pass", "fail"))
  expect_equal(out$verdict,      c("marginal", "fail"))
})

test_that("convergence table + verdict: non-finite or empty diagnostics fail gated groups and read NA, not +-Inf, when descriptive", {
  blk <- function(rhat, ess) matrix(c(rhat, ess), nrow = 2, byrow = TRUE)
  ok  <- list(s1 = blk(1.01, 900))
  chk <- list(
    partial_na = list(mu = blk(c(1.01, NA), c(900, 900)), alpha = ok,
                      sigma2 = blk(c(NA, NA), c(NA, NA)), correlation = blk(c(Inf, Inf), c(Inf, Inf))),
    all_na     = list(mu = blk(c(NA, NA), c(NA, NA)), alpha = ok,
                      sigma2 = blk(1.3, 100), correlation = blk(1.4, 50)),
    empty      = list(mu = blk(1.01, 900), alpha = list(),
                      sigma2 = blk(1.3, 100), correlation = blk(1.4, 50))
  )
  local_mocks(emc_check = function(model, ...) chk[[model]])
  tbl <- create_convergence_table(setNames(as.list(names(chk)), names(chk)))
  tbl <- add_convergence_verdict(tbl, max_rhat_mu = TH$rhat_mu, min_ess_mu = TH$ess_mu,
                                 max_rhat_alpha = TH$rhat_alpha, min_ess_alpha = TH$ess_alpha)
  verdict <- function(m, g) tbl$verdict[tbl$model == m & tbl$group == g]

  expect_equal(verdict("partial_na", "mu"), "fail")      # one NA Rhat spoils an otherwise clean block
  expect_equal(verdict("partial_na", "alpha"), "pass")
  expect_equal(verdict("all_na", "mu"), "fail")
  expect_equal(verdict("empty", "alpha"), "fail")        # a gated block with no values never passes
  expect_equal(verdict("empty", "mu"), "pass")

  expect_true(all(tbl$verdict[tbl$group %in% c("sigma2", "correlation")] == "descriptive"))
  desc <- tbl[tbl$model == "partial_na" & tbl$group %in% c("sigma2", "correlation"), ]
  expect_true(all(is.na(desc$max_rhat)) && all(is.na(desc$min_ess)))   # not -Inf / Inf
  expect_equal(desc$n_nonfinite_rhat, c(2L, 2L))
  expect_false(any(is.infinite(unlist(tbl[sapply(tbl, is.numeric)]))))
})

test_that("metric_verdict: descriptive for sigma2/correlation, NA for unknown groups, error on bad metric", {
  expect_equal(metric_verdict("sigma2", "rhat", 1.30, 60, TH), "descriptive")
  expect_equal(metric_verdict("correlation", "ess", 100, thresholds = TH), "descriptive")
  expect_identical(metric_verdict("theta", "rhat", 1.0, thresholds = TH), NA_character_)
  expect_error(metric_verdict("mu", "bulk", 1.0, thresholds = TH), "metric must be")
})


# =============================================================================
# get_prior_sds()
# =============================================================================

test_that("get_prior_sds returns sqrt(diag(theta_mu_var)) with names", {
  pars <- c("v", "B", "t0")
  V    <- diag(c(4, 1, 0.25)); rownames(V) <- colnames(V) <- pars
  mock_model <- list(list(prior = list(theta_mu_var = V)))
  sds <- get_prior_sds(mock_model)
  expect_equal(unname(sds), c(2, 1, 0.5))
  expect_equal(names(sds), pars)
})

test_that("get_prior_sds errors on missing prior layout", {
  expect_error(get_prior_sds(list(list(prior = list()))), "theta_mu_var")
})


# =============================================================================
# zscore_contraction()
# =============================================================================

test_that("zscore_contraction matches closed form, is vectorised, propagates NA prior_sd", {
  # post_sd = 0.5, prior_sd = 1 -> contraction = 1 - 0.25/1 = 0.75; z = (est - true) / post_sd
  zc <- zscore_contraction(
    mu_est   = c(1.5, 2.0),
    mu_true  = c(1.0, 1.0),
    post_sd  = c(0.5, 0.5),
    prior_sd = c(1.0, NA)
  )
  expect_equal(zc$z_score, c(1, 2))
  expect_equal(zc$contraction[1], 0.75)
  expect_true(is.na(zc$contraction[2]))
})


# =============================================================================
# recovery_subject_rows() / recovery_subject_stats()
# =============================================================================

test_that("recovery_subject_rows aligns estimates to truth by subject and parameter name", {
  true_alpha <- matrix(c(1, 2, 3, 10, 20, 30), nrow = 3,
                       dimnames = list(c("s1", "s2", "s3"), c("v", "B")))
  # Shuffled rows and columns, an extra subject and an extra parameter.
  est <- matrix(c(25, 15, 99, 35, 2.5, 1.5, 99, 3.5, 7, 7, 7, 7), nrow = 4,
                dimnames = list(c("s2", "s1", "s9", "s3"), c("B", "v", "A")))
  local_mocks(alpha_posterior_means = function(fit) est)
  out <- recovery_subject_rows(NULL, true_alpha, "m", 1L)

  expect_equal(nrow(out), 6L)
  expect_equal(out$parameter, rep(c("v", "B"), each = 3))
  expect_equal(out$subject, rep(c("s1", "s2", "s3"), 2))
  expect_equal(out$true, c(1, 2, 3, 10, 20, 30))
  expect_equal(out$est, c(1.5, 2.5, 3.5, 15, 25, 35))

  local_mocks(alpha_posterior_means = function(fit) {
    matrix(1, 1, 1, dimnames = list("other", "v"))
  })
  expect_error(recovery_subject_rows(NULL, true_alpha, "m", 1L), "no overlapping")
})

test_that("align_true_alpha re-orders by name and refuses mismatched subjects or parameters; add_coverage95 only appends", {
  true_alpha <- matrix(1:9, nrow = 3, dimnames = list(c("s1", "s2", "s3"), c("v", "B", "t0")))
  est <- function(rows, cols) matrix(0, length(rows), length(cols), dimnames = list(rows, cols))

  out <- align_true_alpha(true_alpha, est(c("s3", "s1", "s2"), c("t0", "v")))   # shuffled; B is extra
  expect_equal(out, true_alpha[c("s3", "s1", "s2"), c("t0", "v")])
  expect_equal(dim(align_true_alpha(true_alpha, est(c("s2", "s1", "s3"), "B"))), c(3L, 1L))

  expect_error(align_true_alpha(unname(true_alpha), est("s1", "v")), "needs subject")
  expect_error(align_true_alpha(true_alpha, est(c("s1", "s2"), "v")), "subjects differ")
  expect_error(align_true_alpha(true_alpha, est(c("s1", "s2", "s3", "s9"), "v")), "subjects differ")
  expect_error(align_true_alpha(true_alpha, est(c("s1", "s2", "s3"), c("v", "A"))), "missing from true_alpha: A")

  stats <- data.frame(model = c("m", "m", "n"), parameter = c("v", "B", "v"), n = 1:3, rmse = c(.3, .2, .1),
                      stringsAsFactors = FALSE)
  pts <- data.frame(model = c("m", "m", "m", "m", "n"), parameter = c("B", "B", "v", "v", "v"),
                    inside = c(TRUE, FALSE, TRUE, TRUE, FALSE))
  got <- add_coverage95(stats, pts)
  expect_identical(got[names(stats)], stats)
  expect_equal(got$coverage95, c(100, 50, 0))
  expect_true(is.na(add_coverage95(rbind(stats, data.frame(model = "z", parameter = "v", n = 0L, rmse = NA)),
                                   pts)$coverage95[4]))
})

test_that("recovery_subject_stats pools sims per (model, parameter) with closed-form RMSE and r", {
  pts <- data.frame(model = "m", parameter = rep(c("v", "B"), c(4, 2)),
                    sim = c(1, 1, 2, 2, 1, 2),
                    true = c(1, 2, 3, 4, 0, 1), est = c(1, 3, 3, 6, 0, 1))
  out <- recovery_subject_stats(pts)
  v   <- out[out$parameter == "v", ]
  expect_equal(nrow(out), 2L)
  expect_equal(v$n, 4L)
  expect_equal(v$rmse, sqrt(mean(c(0, 1, 0, 4))))
  expect_equal(v$r, cor(c(1, 3, 3, 6), c(1, 2, 3, 4)))
  expect_equal(out$rmse[out$parameter == "B"], 0)
})


# =============================================================================
# flag_identifiable() / recovery_model_summary()
# =============================================================================

PAT <- "^v_StimulusAtLoc[DE](:SearchDifficulty(MIXED|DIFFICULT))?$"

test_that("flag_identifiable applies each model's own pattern; NA = all identifiable; stale pattern errors", {
  pars <- c("v", "v_PrevTargetAtLocTRUE", "B",
            "v_StimulusAtLocD", "v_StimulusAtLocE",
            "v_StimulusAtLocD:SearchDifficultyMIXED",
            "v_StimulusAtLocE:SearchDifficultyDIFFICULT")
  one <- rep("m1", length(pars))
  expect_equal(flag_identifiable(pars, one, c(m1 = PAT)),
               c(TRUE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE))
  expect_true(all(flag_identifiable(pars, one, c(m1 = NA_character_))))

  # two models stacked: m1 uses PAT, m2 only flags "B"
  two <- flag_identifiable(c(pars, "v", "B"), c(one, "m2", "m2"),
                           c(m1 = PAT, m2 = "^B$"))
  expect_equal(two, c(TRUE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, TRUE, FALSE))

  # interleaved rows with shared names: each row follows its own model only, order kept
  mix_par <- c("B", "v", "B", "v")
  mix_mod <- c("m2", "m1", "m1", "m2")
  expect_equal(flag_identifiable(mix_par, mix_mod, c(m1 = "^v$", m2 = NA_character_)),
               c(TRUE, FALSE, TRUE, TRUE))
  expect_equal(flag_identifiable(mix_par, mix_mod, c(m1 = NA_character_, m2 = "^B$")),
               c(FALSE, TRUE, TRUE, TRUE))

  expect_error(flag_identifiable(pars, one, c(m1 = "^nope$")), "m1.*matches none")
  expect_error(flag_identifiable(pars, one, c(other = PAT)), "No unidentifiability pattern for model 'm1'")
})

test_that("recovery_model_summary computes full and core means, per-model patterns", {
  ss <- data.frame(
    model     = "model4",
    parameter = c("v", "v_StimulusAtLocD", "v_StimulusAtLocE:SearchDifficultyDIFFICULT"),
    n         = 10,
    rmse      = c(0.2, 0.9, 8.0),
    r         = c(0.9, -0.3, -0.7),
    stringsAsFactors = FALSE
  )
  out <- recovery_model_summary(ss, c(model4 = PAT))
  expect_equal(out$n_all, 3)
  expect_equal(out$n_core, 1)              # only "v" survives
  expect_equal(out$r_core, 0.9)            # core mean = just v
  expect_equal(round(out$r_all, 4), round(mean(c(0.9, -0.3, -0.7)), 4))

  ss2 <- rbind(ss, transform(ss, model = "model_na"))
  out2 <- recovery_model_summary(ss2, c(model4 = PAT, model_na = NA_character_))
  expect_equal(out2$n_core[match(c("model4", "model_na"), out2$model)], c(1, 3))   # model4 flagged, model_na untouched
  na_row <- out2[out2$model == "model_na", ]
  expect_equal(na_row$rmse_core, na_row$rmse_all)   # NA pattern: core == full exactly
  expect_equal(na_row$r_core, na_row$r_all)

  # changing model_na's pattern leaves model4's stats untouched, and vice versa
  out3 <- recovery_model_summary(ss2, c(model4 = PAT, model_na = "^v$"))
  expect_equal(out3[out3$model == "model4", ], out2[out2$model == "model4", ])
  expect_equal(out3$rmse_core[out3$model == "model_na"], mean(c(0.9, 8.0)))   # hand computation on the 2 rows left
})

test_that("model_unidentifiable_pattern reads the script's declaration in isolation and rejects bad ones", {
  fixtures <- file.path(ROOT, "__tests__", "fixtures")
  leaks <- function() c("build_model", "MODEL_NAME") %in% ls(globalenv(), all.names = TRUE)
  before <- leaks()
  expect_identical(model_unidentifiable_pattern("test_model", fixtures), NA_character_)
  expect_identical(leaks(), before)
  expect_false(exists("build_model", envir = environment(), inherits = FALSE))

  dir <- withr::local_tempdir()
  write_script <- function(name, body) writeLines(body, file.path(dir, paste0(name, ".R")))
  write_script("ok",     "STRUCTURAL_UNIDENTIFIABLE_PATTERN <- '^v_x$'")
  write_script("none",   "MODEL_NAME <- 'none'")
  write_script("num",    "STRUCTURAL_UNIDENTIFIABLE_PATTERN <- 1")
  write_script("vec",    "STRUCTURAL_UNIDENTIFIABLE_PATTERN <- c('a', 'b')")
  write_script("badre",  "STRUCTURAL_UNIDENTIFIABLE_PATTERN <- '(['")
  expect_equal(model_unidentifiable_pattern("ok", dir), "^v_x$")
  expect_error(model_unidentifiable_pattern("absent", dir), "absent.*script not found")
  expect_error(model_unidentifiable_pattern("none", dir),   "does not define STRUCTURAL_UNIDENTIFIABLE_PATTERN")
  expect_error(model_unidentifiable_pattern("num", dir),    "single character string")
  expect_error(model_unidentifiable_pattern("vec", dir),    "single character string")
  expect_error(model_unidentifiable_pattern("badre", dir),  "not a valid regex")
})

test_that("every model script defining build_model declares a valid STRUCTURAL_UNIDENTIFIABLE_PATTERN", {
  undeclared <- function(dirs) {
    scripts <- unlist(lapply(dirs, list.files, pattern = "[.]R$", full.names = TRUE))
    defines <- Filter(function(f) any(grepl("^build_model[[:space:]]*<-[[:space:]]*function", readLines(f, warn = FALSE))), scripts)
    problems <- vapply(defines, function(f) {
      tryCatch({ model_unidentifiable_pattern(tools::file_path_sans_ext(basename(f)), dirname(f)); "" },
               error = conditionMessage)
    }, character(1))
    problems[nzchar(problems)]
  }
  expect_length(undeclared(c(file.path(ROOT, "R", "fit"), file.path(ROOT, "__tests__", "fixtures"))), 0L)

  # the scan really fails for a model script that forgot the declaration
  dir <- withr::local_tempdir()
  writeLines("MODEL_NAME <- 'forgot'
build_model <- function(data, n_chains) NULL", file.path(dir, "forgot.R"))
  writeLines("STRUCTURAL_UNIDENTIFIABLE_PATTERN <- NA_character_
build_model <- function(data, n_chains) NULL",
             file.path(dir, "fine.R"))
  found <- undeclared(dir)
  expect_named(found, file.path(dir, "forgot.R"))
  expect_match(found[[1]], "does not define STRUCTURAL_UNIDENTIFIABLE_PATTERN")
})
