#' =============================================================================
#' The ONLY place that runs the AWS CLI. Everything else calls the thin aws_*
#' wrappers below, which tests mock (the seam, like R/helpers/emc2_api.R).
#'
#' Safety rules enforced here:
#'   - refuse to run if ambient credentials / profile env vars are set (only the
#'     SSO profile `paf-agent` may be used);
#'   - raw CLI output is parsed, never echoed; error text is redacted first;
#'   - an expired SSO session is reported with the command the USER must run.
#'
#' Source chain: aws_api.R -> cloud_config.R
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/cloud/cloud_config.R")

FORBIDDEN_AWS_ENV <- c("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                       "AWS_PROFILE", "AWS_DEFAULT_PROFILE")


#' Stop if any ambient AWS credential / profile env var is set.
aws_guard_env <- function() {
  set <- FORBIDDEN_AWS_ENV[nzchar(Sys.getenv(FORBIDDEN_AWS_ENV, unset = ""))]
  if (length(set) > 0L) {
    stop(sprintf("Refusing to run: %s set in the environment. Unset it (the wrapper uses only the '%s' SSO profile).",
                 paste(set, collapse = ", "), AWS_PROFILE_NAME), call. = FALSE)
  }
  invisible(TRUE)
}


#' Strip anything credential- or account-shaped from CLI error text.
redact_aws_text <- function(text) {
  text <- gsub("(AKIA|ASIA)[A-Z0-9]{16}", "<redacted-key>", text)
  text <- gsub("arn:aws[a-z-]*:[^ \"']+", "<redacted-arn>", text)
  text <- gsub("[A-Za-z0-9/+=]{40,}", "<redacted>", text)
  gsub("\\b[0-9]{12}\\b", "<redacted-id>", text)
}


is_sso_expired <- function(text) {
  grepl("sso login|SSO session|SSO Token|token (has )?expired|ExpiredToken|Unable to locate credentials|InvalidGrantException",
        text, ignore.case = TRUE)
}


#' Quote one argument for system2 only if it needs it.
quote_arg <- function(a) if (grepl("[^A-Za-z0-9._/:=,@+%-]", a)) shQuote(a) else a


#' Run `aws <args> --profile .. --region .. --output json`.
#'
#' @param args  Character vector of CLI arguments (no credentials, no secrets).
#' @param parse If TRUE return the parsed JSON (NULL for empty output); if FALSE
#'   return invisible(NULL) (commands such as `s3 cp` print no JSON).
aws_call <- function(args, parse = TRUE) {
  aws_guard_env()
  err_file <- tempfile("aws_err_")
  on.exit(unlink(err_file), add = TRUE)
  full <- c(args, "--profile", AWS_PROFILE_NAME, "--region", AWS_REGION, "--output", "json")
  out <- suppressWarnings(system2("aws", unname(vapply(full, quote_arg, character(1))),
                                  stdout = TRUE, stderr = err_file))
  status <- attr(out, "status")
  if (!is.null(status) && status != 0L) {
    err <- paste(c(out, readLines(err_file, warn = FALSE)), collapse = "\n")
    if (is_sso_expired(err)) {
      stop(sprintf("AWS SSO session is missing or expired. Run this yourself in a terminal, then retry:\n  aws sso login --profile %s",
                   AWS_PROFILE_NAME), call. = FALSE)
    }
    stop(sprintf("aws %s failed (exit %d): %s", args[[1]], status,
                 substr(redact_aws_text(err), 1L, 600L)), call. = FALSE)
  }
  if (!parse) return(invisible(NULL))
  text <- paste(out, collapse = "\n")
  if (!nzchar(trimws(text))) return(NULL)
  tryCatch(jsonlite::fromJSON(text, simplifyVector = FALSE),
           error = function(e) stop(sprintf("aws %s returned unparsable output", args[[1]]), call. = FALSE))
}


#' A temp JSON file for `file://` arguments (PowerShell-safe, no inline JSON).
json_arg_file <- function(x) {
  path <- tempfile("aws_arg_", fileext = ".json")
  writeLines(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null"), path)
  paste0("file://", normalizePath(path, winslash = "/"))
}


s3_split <- function(key = "") {
  parts <- strsplit(CLOUD_BUCKET_ROOT, "/", fixed = TRUE)[[1]]
  list(bucket = parts[[1]], prefix = paste(c(parts[-1], key), collapse = "/"))
}


#' `s3://` URI of a key under the project bucket root.
s3_uri <- function(key) sprintf("s3://%s/%s", CLOUD_BUCKET_ROOT, key)


# -----------------------------------------------------------------------------
# Thin wrappers (the mock seam)
# -----------------------------------------------------------------------------

#' Caller identity reduced to the SSO role name and region (no account ID, no ARN).
aws_whoami <- function() {
  res <- aws_call(c("sts", "get-caller-identity"))
  m <- regmatches(res$Arn, regexec("assumed-role/([^/]+)/", res$Arn))[[1]]
  list(role = if (length(m) == 2L) m[[2]] else NA_character_, region = AWS_REGION)
}


#' @param env  Named list/character of container environment overrides.
#' @param resources list(vcpu=, memory_mib=) sizing override (no command override).
#' @param tags Named character vector of Batch tags (propagated to the instance).
#' @return The submitted job id.
aws_submit_job <- function(job_name, queue, env, resources, tags, timeout_hours, depends_on = character(0)) {
  overrides <- list(
    environment = unname(Map(function(n, v) list(name = n, value = as.character(v)), names(env), env)),
    resourceRequirements = list(list(type = "VCPU", value = as.character(resources$vcpu)),
                                list(type = "MEMORY", value = as.character(resources$memory_mib)))
  )
  args <- c("batch", "submit-job", "--job-name", job_name, "--job-queue", queue,
            "--job-definition", BATCH_JOB_DEFINITION,
            "--container-overrides", json_arg_file(overrides),
            "--tags", paste(sprintf("%s=%s", names(tags), tags), collapse = ","),
            "--propagate-tags",
            "--timeout", sprintf("attemptDurationSeconds=%d", as.integer(round(timeout_hours * 3600))))
  if (length(depends_on) > 0L) args <- c(args, "--depends-on", paste0("jobId=", depends_on))
  aws_call(args)$jobId
}


#' @return List of job description lists (ids in batches of 100).
aws_describe_jobs <- function(job_ids) {
  jobs <- list()
  for (chunk in split(job_ids, ceiling(seq_along(job_ids) / 100))) {
    jobs <- c(jobs, aws_call(c("batch", "describe-jobs", "--jobs", chunk))$jobs)
  }
  jobs
}


#' @return Character vector of job ids in `queue` with `status`.
aws_list_jobs <- function(queue, status) {
  res <- aws_call(c("batch", "list-jobs", "--job-queue", queue, "--job-status", status))
  vapply(res$jobSummaryList, function(j) j$jobId, character(1))
}


aws_terminate_job <- function(job_id, reason = "terminated by paf_aws.R") {
  aws_call(c("batch", "terminate-job", "--job-id", job_id, "--reason", reason), parse = FALSE)
}


#' @return Character vector of the last `tail` log messages of a stream.
aws_log_events <- function(log_stream, tail = 50L) {
  res <- aws_call(c("logs", "get-log-events", "--log-group-name", BATCH_LOG_GROUP,
                    "--log-stream-name", log_stream, "--limit", as.character(as.integer(tail)),
                    "--no-start-from-head"))
  vapply(res$events, function(e) e$message, character(1))
}


#' Highest current Linux spot price (USD/h) over availability zones.
aws_spot_price <- function(instance_type) {
  res <- aws_call(c("ec2", "describe-spot-price-history", "--instance-types", instance_type,
                    "--product-descriptions", "Linux/UNIX",
                    "--start-time", format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")))
  prices <- vapply(res$SpotPriceHistory, function(p) as.numeric(p$SpotPrice), numeric(1))
  if (length(prices) == 0L) stop(sprintf("No spot price returned for %s", instance_type), call. = FALSE)
  max(prices)
}


#' @return data.frame(key, size, last_modified) of objects under a project key prefix.
aws_s3_ls <- function(key_prefix) {
  loc <- s3_split(key_prefix)
  res <- aws_call(c("s3api", "list-objects-v2", "--bucket", loc$bucket, "--prefix", loc$prefix))
  items <- res$Contents
  if (length(items) == 0L) return(data.frame(key = character(), size = numeric(), last_modified = character()))
  root <- paste0(s3_split()$prefix, "/")
  data.frame(key = sub(paste0("^", root), "", vapply(items, function(i) i$Key, character(1))),
             size = vapply(items, function(i) as.numeric(i$Size), numeric(1)),
             last_modified = vapply(items, function(i) i$LastModified, character(1)),
             stringsAsFactors = FALSE)
}


#' Copy between local paths and `s3://` URIs (either direction, or S3 to S3).
aws_s3_cp <- function(src, dst) {
  aws_call(c("s3", "cp", src, dst, "--only-show-errors"), parse = FALSE)
}


#' Unblended account cost (USD) from `start` to `end` (exclusive), as dates.
aws_cost_mtd <- function(start, end) {
  res <- aws_call(c("ce", "get-cost-and-usage",
                    "--time-period", sprintf("Start=%s,End=%s", format(start), format(end)),
                    "--granularity", "MONTHLY", "--metrics", "UnblendedCost"))
  sum(vapply(res$ResultsByTime, function(r) as.numeric(r$Total$UnblendedCost$Amount), numeric(1)))
}


#' Stop unless the active identity is the least-privilege agent role.
aws_assert_role <- function() {
  who <- aws_whoami()
  if (is.na(who$role) || !startsWith(who$role, AWS_ROLE_PREFIX)) {
    stop(sprintf("Wrong AWS identity: expected a role starting with '%s'.", AWS_ROLE_PREFIX), call. = FALSE)
  }
  invisible(who)
}
