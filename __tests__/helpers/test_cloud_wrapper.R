#' =============================================================================
#' Level-1 tests for the AWS Batch wrapper (R/cloud/): no AWS, no network, no
#' real git. The aws_* seam (R/cloud/helpers/aws_api.R) and git_call() are
#' mocked, and all state (plans, ledger, cache) goes to temp dirs.
#' =============================================================================

library(testthat)

ROOT <- Sys.getenv("PAF_REPO_ROOT", unset = getwd())
source(file.path(ROOT, "R", "utils.R"))
source_root("R/cloud/helpers/plan.R")
source_root("R/cloud/helpers/sync.R")
source(file.path(ROOT, "__tests__", "fixtures", "common.R"))   # local_mocks(), call_recorder()

T0 <- as.POSIXct("2026-11-26 10:00:00", tz = "UTC")
FAKE_SHA <- strrep("a", 40)

fake_git <- function(args) {
  if (args[[1]] == "rev-parse") return(list(status = 0L, out = FAKE_SHA))
  if (args[[1]] == "branch") return(list(status = 0L, out = "  origin/main"))
  list(status = 0L, out = character(0))
}

# Redirect all wrapper state to a temp dir and mock every external call.
# Returns the recorder of S3 copies (ledger mirror).
local_cloud_env <- function(.frame = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = .frame)
  s3 <- call_recorder()
  local_mocks(
    CLOUD_PLANS_DIR = file.path(dir, "plans"), CLOUD_LEDGER = file.path(dir, "ledger.jsonl"),
    CLOUD_CACHE_DIR = file.path(dir, "cache"),
    aws_assert_role = function() invisible(TRUE), git_call = fake_git,
    aws_spot_price = function(instance_type) 0.30, aws_cost_mtd = function(start, end) 5,
    aws_s3_cp = s3$fn, .frame = .frame)
  s3
}

fit_specs <- function(n) {
  one <- c("fit", "--model-script", "R/fit/m.R")
  parse_plan_args(unlist(lapply(seq_len(n), function(i) if (i == 1L) one else c("+", one))))
}


test_that("guard: any ambient AWS credential/profile var aborts without echoing its value", {
  # Why: only the SSO profile may be used, and a token must never reach the console.
  withr::local_envvar(AWS_ACCESS_KEY_ID = NA, AWS_SECRET_ACCESS_KEY = NA, AWS_SESSION_TOKEN = NA,
                      AWS_PROFILE = NA, AWS_DEFAULT_PROFILE = NA)
  expect_silent(aws_guard_env())
  withr::local_envvar(AWS_SESSION_TOKEN = "tok-SECRET-123")
  err <- expect_error(aws_guard_env(), "AWS_SESSION_TOKEN")
  expect_false(grepl("SECRET", conditionMessage(err)))
  withr::local_envvar(AWS_SESSION_TOKEN = NA, AWS_PROFILE = "other")
  expect_error(aws_guard_env(), "AWS_PROFILE")
})


test_that("role check: whoami exposes only role+region; a non-agent role is refused", {
  # Why: a wrong identity must stop everything, and account ids/ARNs must not leak.
  arn <- function(role) list(Arn = sprintf("arn:aws:sts::000000000000:assumed-role/%s/me", role))
  local_mocks(aws_call = function(args, parse = TRUE) arn("AWSReservedSSO_PafAgent_abc123"))
  who <- aws_whoami()
  expect_equal(who$role, "AWSReservedSSO_PafAgent_abc123")
  expect_false(grepl("000000000000", paste(unlist(who), collapse = " ")))
  expect_silent(aws_assert_role())

  local_mocks(aws_call = function(args, parse = TRUE) arn("AWSReservedSSO_AdministratorAccess_x"))
  err <- expect_error(aws_assert_role(), "Wrong AWS identity")
  expect_false(grepl("Administrator|000000000000", conditionMessage(err)))
})


test_that("spec validation: bad tokens, unknown kind/env and missing model scripts are rejected", {
  # Why: PAF_ARGS reaches a shell in the container, so injection must die at plan time.
  expect_silent(validate_arg_tokens(c("--model-script", "R/fit/m.R", "--n=3", "260101_m.rds")))
  for (bad in c("a;b", "$(x)", "a b", "../x", "`x`", "a|b", "")) expect_error(validate_arg_tokens(bad), "Invalid argument")

  opts <- parse_plan_args(c("fit", "--model-script", "R/fit/m.R", "+", "smoke", "--ref", "dev", "--market", "on-demand",
                            "--env", "FIT_DIR=outputs/x"))
  expect_equal(vapply(opts$specs, `[[`, "", 1L), c("fit", "smoke"))
  expect_equal(c(opts$ref, opts$market, opts$env$FIT_DIR), c("dev", "on-demand", "outputs/x"))
  expect_error(parse_plan_args(c("fit", "--market", "free")), "spot")
  expect_error(make_jobs(list(c("rm", "-rf"))), "Unknown kind")
  expect_error(validate_jobs(make_jobs(list("fit"), list(AWS_REGION = "x")), FAKE_SHA), "not allowed")

  local_mocks(git_call = function(args) list(status = if (args[[1]] == "cat-file") 1L else 0L, out = "  origin/main"))
  expect_error(validate_model_scripts(c("--model-script", "R/fit/gone.R"), FAKE_SHA), "does not exist")
})


test_that("layout: jobs run in parallel up to the vCPU cap, then serially in waves", {
  # Why: the cap (64 spot / 16 on-demand) is what bounds concurrent spend.
  expect_equal(layout_jobs(rep(16L, 4), 64L), list(1:4))
  expect_equal(layout_jobs(rep(16L, 5), 64L), list(1:4, 5L))
  expect_equal(layout_jobs(rep(16L, 3), 16L), list(1L, 2L, 3L))
  expect_equal(layout_jobs(c(16L, 4L, 4L, 16L), 20L), list(1:2, 3:4))   # order-preserving
  expect_error(layout_jobs(16L, 8L), "above the cap")
})


test_that("cost estimate: wall = sum of wave maxima, cost = sum of hours x price, unknown falls back to timeout", {
  # Why: this arithmetic is what the user approves before money is spent.
  jobs <- data.frame(wall_hours = c(10, 6, 4), timeout_hours = c(24, 24, 12), price_hr = c(0.3, 0.3, 0.5))
  est <- estimate_cost(jobs, list(1:2, 3L))
  expect_equal(est$est_wall_hours, 10 + 4)
  expect_equal(est$est_cost_usd, 10 * 0.3 + 6 * 0.3 + 4 * 0.5)
  expect_equal(est$max_wall_hours, 24 + 12)
  expect_equal(est$max_cost_usd, 24 * 0.3 + 24 * 0.3 + 12 * 0.5)

  unknown <- estimate_cost(transform(jobs, wall_hours = NA_real_), list(1:3))
  expect_true(is.na(unknown$est_cost_usd))
  expect_equal(unknown$max_cost_usd, est$max_cost_usd)

  expect_false(budget_check(10, 5, 99, budget = 50)$over)
  over <- budget_check(40, NA_real_, 20, budget = 50)
  expect_true(over$over)
  expect_equal(c(over$basis, over$projected_usd), c("worst case", "60"))
})


test_that("plan id is stable across re-plans; expired and tampered plans are refused", {
  # Why: launch must run exactly what was approved, and only while the quote is fresh.
  local_cloud_env()
  p1 <- plan_create(parse_plan_args("smoke"), now = T0)
  p2 <- plan_create(parse_plan_args("smoke"), now = T0 + 60)
  expect_equal(p1$id, p2$id)
  expect_false(identical(plan_id(plan_create(parse_plan_args(c("smoke", "--market", "on-demand")), now = T0)), p1$id))

  expect_equal(plan_load(p1$id, now = T0 + 600)$id, p1$id)
  expect_error(plan_load(p1$id, now = T0 + 60 + 31 * 60), "expired")

  raw <- jsonlite::fromJSON(plan_path(p1$id), simplifyVector = FALSE)
  raw$jobs[[1]]$timeout_hours <- 100
  writeLines(jsonlite::toJSON(raw, auto_unbox = TRUE, digits = NA), plan_path(p1$id))
  expect_error(plan_load(p1$id, now = T0 + 600), "modified")
  expect_error(plan_load("../../etc", now = T0), "Invalid plan id")
})


test_that("launch submits env-only overrides with the required tags, wave by wave, once", {
  # Why: the wrapper must never override the command, must tag for cost tracking, and serial waves must chain.
  local_cloud_env()
  n <- 0L
  sub <- call_recorder(function(...) { n <<- n + 1L; sprintf("job-%d", n) })
  local_mocks(aws_submit_job = sub$fn, active_vcpus = function() c(spot = 0L, ondemand = 0L))
  plan <- plan_create(fit_specs(5), now = T0)
  ids <- plan_launch(plan$id, now = T0 + 60)
  calls <- sub$calls()

  expect_equal(ids, sprintf("job-%d", 1:5))
  expect_equal(length(calls), 5L)
  expect_equal(names(calls[[1]]$env), c("PAF_GIT_SHA", "PAF_KIND", "PAF_ARGS", "PAF_RUN_ID", "BUCKET"))
  expect_equal(calls[[1]]$env$PAF_GIT_SHA, FAKE_SHA)
  expect_equal(calls[[1]]$env$PAF_ARGS, "--model-script R/fit/m.R")
  expect_equal(names(calls[[2]]$tags), c("Project", "Owner", "PlanId", "Kind"))
  expect_equal(unname(calls[[2]]$tags[c("Project", "Owner", "Kind")]), c("paf", "agent", "fit"))
  expect_equal(calls[[2]]$tags[["PlanId"]], plan$id)
  expect_equal(calls[[1]]$depends_on, character(0))
  expect_equal(calls[[5]]$depends_on, ids[1:4])
  expect_error(plan_launch(plan$id, now = T0 + 120), "already launched")
})


test_that("aws_submit_job sends only environment + resource overrides (never a command) and propagates tags", {
  # Why: the container's default command is the contract; the JSON payload is the last place to break it.
  rec <- call_recorder(function(args, parse = TRUE) list(jobId = "job-1"))
  local_mocks(aws_call = rec$fn)
  aws_submit_job("paf-smoke-x-1", "paf-spot", list(PAF_KIND = "smoke"), list(vcpu = 4L, memory_mib = 6000L),
                 c(Project = "paf", Owner = "agent"), timeout_hours = 0.5)
  args <- rec$calls()[[1]][[1]]
  overrides <- jsonlite::fromJSON(sub("^file://", "", args[which(args == "--container-overrides") + 1L]),
                                  simplifyVector = FALSE)
  expect_setequal(names(overrides), c("environment", "resourceRequirements"))
  expect_equal(overrides$environment[[1]], list(name = "PAF_KIND", value = "smoke"))
  expect_true("--propagate-tags" %in% args)
  expect_equal(args[which(args == "--tags") + 1L], "Project=paf,Owner=agent")
  expect_equal(args[which(args == "--timeout") + 1L], "attemptDurationSeconds=1800")
  expect_equal(args[which(args == "--job-definition") + 1L], BATCH_JOB_DEFINITION)
})


test_that("ledger: events mirror to a dated S3 key; only successful runs feed the wall-time median", {
  # Why: the ledger is the audit trail and the source of the unknown-wall-time estimates.
  s3 <- local_cloud_env()
  for (h in c(2, 4, 9)) ledger_append("finished", "p1", list(job_id = paste0("j", h), kind = "fit", status = "SUCCEEDED", runtime_hours = h))
  ledger_append("finished", "p1", list(job_id = "jx", kind = "fit", status = "FAILED", runtime_hours = 99))
  expect_equal(length(ledger_read()), 4L)
  expect_equal(ledger_median_hours("fit"), 4)
  expect_true(is.na(ledger_median_hours("bf")))
  expect_equal(wall_hours_for("fit"), 4)
  expect_equal(wall_hours_for("smoke"), 0.25)   # configured value wins over the ledger
  expect_match(s3$calls()[[1]][[2]], "^s3://jon-nir/paf-models/ledger/[0-9]{4}-[0-9]{2}/[0-9]{8}T[0-9]{6}Z_p1_finished\\.json$")
})


test_that("promote: latest date per model, sensitivity fits excluded unless asked, existing inputs never overwritten", {
  # Why: promoting the wrong fit silently changes every downstream resume/recovery/PPC input.
  keys <- c("260101_m1.rds", "260301_m1.rds", "260201_m1_extended.rds", "260101_m2.rds", "260401_m2_sd2.rds", "log_fit_m1.txt")
  expect_equal(select_latest_per_model(keys), c("260301_m1.rds", "260101_m2.rds"))
  expect_equal(select_latest_per_model(keys, include_sensitivity = TRUE),
               c("260301_m1.rds", "260101_m2.rds", "260401_m2_sd2.rds"))
  expect_error(select_latest_per_model(c("260301_m1.rds", "260301_m1_extended.rds")), "Ambiguous")

  ls_df <- function(k) data.frame(key = k, size = 1, last_modified = "x")
  cp <- call_recorder()
  local_mocks(aws_s3_ls = function(prefix) if (prefix == "results/fit/") ls_df(paste0("results/fit/", keys)) else ls_df("inputs/fit/260301_m1.rds"),
              aws_s3_cp = cp$fn)
  res <- promote_fits()
  expect_equal(res$status, c("exists", "promoted"))
  expect_equal(length(cp$calls()), 1L)
  expect_equal(unlist(cp$calls()[[1]]), c("s3://jon-nir/paf-models/results/fit/260101_m2.rds", "s3://jon-nir/paf-models/inputs/fit/260101_m2.rds"))
})
