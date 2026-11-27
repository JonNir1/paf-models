#' =============================================================================
#' Agent-facing AWS Batch wrapper CLI. Run from the repo root, normally through
#' scripts/paf-aws.ps1:
#'
#'   whoami                                   role name + region only
#'   plan <kind> <args...> [+ <kind> <args...>]... [--ref <branch>]
#'        [--market spot|on-demand] [--env NAME=VALUE]...
#'   launch <plan-id>                         re-validate, then submit
#'   status [plan-id|job-id]
#'   logs <job-id> [--tail N]
#'   terminate <job-id|plan-id>
#'   cost                                     month-to-date vs budget
#'   sync <kind>                              S3 results -> main checkout outputs/
#'   promote [--include-sensitivity]          results/fit -> inputs/fit (latest per model)
#'
#' Credentials come only from the SSO profile `paf-agent`; if the session has
#' expired the user must run `aws sso login --profile paf-agent` themselves.
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/helpers/logging.R")
source_root("R/cloud/helpers/plan.R")
source_root("R/cloud/helpers/sync.R")

JOB_ID_REGEX <- "^[A-Za-z0-9-]{8,64}$"
TERMINAL_STATES <- c("SUCCEEDED", "FAILED")


say <- function(...) cat(..., "\n", sep = "")


#' Job ids of a plan's latest `launched` event (ledger).
plan_job_ids <- function(plan_id) {
  events <- Filter(function(r) identical(r$event, "launched") && identical(r$plan_id, plan_id), ledger_read())
  if (length(events) == 0L) stop(sprintf("Plan %s has no launched jobs in the ledger", plan_id), call. = FALSE)
  as.character(unlist(events[[length(events)]]$job_ids))
}


#' Hourly price a plan recorded for a kind's instance type (NA if the plan file is gone).
recorded_price <- function(plan_id, kind) {
  path <- plan_path(plan_id)
  if (!file.exists(path)) return(NA_real_)
  plan <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  type <- Filter(function(j) identical(j$kind, kind), plan$jobs)[[1]]$instance_type
  as.numeric(or_default(plan$prices[[type]], NA_real_))
}


#' Log a `finished` event for each job that reached a terminal state and has none yet.
record_finished <- function(jobs) {
  done <- ledger_finished_jobs()
  for (j in jobs) {
    if (!j$status %in% TERMINAL_STATES || j$jobId %in% done || is.null(j$startedAt) || is.null(j$stoppedAt)) next
    hours <- (j$stoppedAt - j$startedAt) / 3.6e6
    plan_id <- or_default(j$tags$PlanId, "unknown")
    kind <- or_default(j$tags$Kind, "unknown")
    price <- recorded_price(plan_id, kind)
    ledger_append("finished", plan_id, list(job_id = j$jobId, kind = kind, status = j$status,
                                            runtime_hours = round(hours, 4),
                                            est_actual_cost_usd = round(hours * price, 4)))
  }
}


print_jobs <- function(jobs) {
  for (j in jobs) {
    hours <- if (!is.null(j$startedAt)) ((or_default(j$stoppedAt, as.numeric(Sys.time()) * 1000)) - j$startedAt) / 3.6e6 else NA_real_
    say(sprintf("%s  %-10s %-28s %s", j$jobId, j$status, j$jobName,
                if (is.na(hours)) "" else sprintf("%.2f h", hours)))
    if (!is.null(j$statusReason)) say("    ", substr(redact_aws_text(j$statusReason), 1L, 200L))
  }
}


cmd_whoami <- function(args) {
  who <- aws_assert_role()
  say(sprintf("role: %s\nregion: %s", who$role, who$region))
}


cmd_plan <- function(args) {
  plan <- plan_create(parse_plan_args(args))
  cat(format_plan(plan), sep = "\n")
}


cmd_launch <- function(args) {
  if (length(args) != 1L) stop("usage: launch <plan-id>", call. = FALSE)
  ids <- plan_launch(args[[1]])
  say(sprintf("Launched %d job(s) for plan %s:", length(ids), args[[1]]))
  for (id in ids) say("  ", id)
  say("Check progress with: status ", args[[1]])
}


cmd_status <- function(args) {
  aws_assert_role()
  target <- if (length(args) >= 1L) args[[1]] else NULL
  if (is.null(target)) {
    records <- ledger_read()
    launched <- unlist(lapply(Filter(function(r) identical(r$event, "launched"), records), function(r) r$job_ids))
    ids <- setdiff(launched, ledger_finished_jobs(records))
    if (length(ids) == 0L) return(say("No unfinished jobs in the ledger."))
  } else if (grepl(PLAN_ID_REGEX, target)) {
    ids <- plan_job_ids(target)
  } else if (grepl(JOB_ID_REGEX, target)) {
    ids <- target
  } else stop("usage: status [plan-id|job-id]", call. = FALSE)
  jobs <- aws_describe_jobs(ids)
  record_finished(jobs)
  print_jobs(jobs)
}


cmd_logs <- function(args) {
  aws_assert_role()
  if (length(args) < 1L || !grepl(JOB_ID_REGEX, args[[1]])) stop("usage: logs <job-id> [--tail N]", call. = FALSE)
  tail <- parse_int_arg(args, "--tail")
  tail <- if (is.null(tail) || is.na(tail)) 50L else min(max(tail, 1L), 1000L)
  job <- aws_describe_jobs(args[[1]])[[1]]
  stream <- job$container$logStreamName
  if (is.null(stream)) stop("Job has no log stream yet (not started?)", call. = FALSE)
  cat(redact_aws_text(aws_log_events(stream, tail)), sep = "\n")
}


cmd_terminate <- function(args) {
  aws_assert_role()
  if (length(args) != 1L) stop("usage: terminate <job-id|plan-id>", call. = FALSE)
  ids <- if (grepl(PLAN_ID_REGEX, args[[1]])) plan_job_ids(args[[1]]) else if (grepl(JOB_ID_REGEX, args[[1]])) args[[1]] else
    stop("usage: terminate <job-id|plan-id>", call. = FALSE)
  jobs <- aws_describe_jobs(ids)
  for (j in jobs) {
    if (j$status %in% TERMINAL_STATES) next
    aws_terminate_job(j$jobId)
    ledger_append("terminated", or_default(j$tags$PlanId, "unknown"), list(job_id = j$jobId, kind = or_default(j$tags$Kind, "unknown")))
    say("terminated ", j$jobId)
  }
  say("Done (jobs already finished were left alone).")
}


cmd_cost <- function(args) {
  aws_assert_role()
  mtd <- month_to_date_spend()
  say(sprintf("Month-to-date account spend: %s of %s budget (%s)", fmt_usd(mtd$amount), fmt_usd(MONTHLY_BUDGET_USD),
              if (mtd$cached) sprintf("cached, fetched %s", format(mtd$fetched_at, PLAN_TIME_FORMAT, tz = "UTC")) else "fresh"))
  month <- format(Sys.time(), "%Y-%m", tz = "UTC")
  finished <- Filter(function(r) identical(r$event, "finished") && startsWith(r$ts, month), ledger_read())
  est <- sum(vapply(finished, function(r) as.numeric(or_default(r$est_actual_cost_usd, 0)), numeric(1)), na.rm = TRUE)
  say(sprintf("Ledger: %d finished job(s) this month, est. compute cost %s", length(finished), fmt_usd(est)))
}


cmd_sync <- function(args) {
  aws_assert_role()
  if (length(args) != 1L) stop(sprintf("usage: sync <%s>", paste(names(SYNC_TARGETS), collapse = "|")), call. = FALSE)
  res <- sync_results(args[[1]])
  say(sprintf("%d downloaded, %d already present (never overwritten).", sum(res$status == "downloaded"), sum(res$status == "exists")))
  for (f in res$file[res$status == "downloaded"]) say("  + ", f)
}


cmd_promote <- function(args) {
  aws_assert_role()
  res <- promote_fits(include_sensitivity = "--include-sensitivity" %in% args)
  say(sprintf("%d promoted, %d already in inputs/fit/ (never overwritten).", sum(res$status == "promoted"), sum(res$status == "exists")))
  for (i in seq_len(nrow(res))) say(sprintf("  %-9s %s", res$status[[i]], res$file[[i]]))
}


COMMANDS <- list(whoami = cmd_whoami, plan = cmd_plan, launch = cmd_launch, status = cmd_status, logs = cmd_logs,
                 terminate = cmd_terminate, cost = cmd_cost, sync = cmd_sync, promote = cmd_promote)


main <- function(argv) {
  tryCatch({
    aws_guard_env()
    if (length(argv) == 0L || !argv[[1]] %in% names(COMMANDS)) {
      stop(sprintf("usage: paf-aws <%s> ...", paste(names(COMMANDS), collapse = "|")), call. = FALSE)
    }
    COMMANDS[[argv[[1]]]](argv[-1])
  }, error = function(e) {
    cat("ERROR: ", conditionMessage(e), "\n", sep = "", file = stderr())
    quit(status = 1L)
  })
}


if (sys.nframe() == 0L) main(commandArgs(trailingOnly = TRUE))
