#' =============================================================================
#' Append-only ledger of cloud job events, kept locally (.paf-aws/ledger.jsonl)
#' and mirrored to S3 (ledger/<YYYY-MM>/<UTC ts>_<planid>_<event>.json).
#'
#' Events: planned, launched, terminated, finished (actual runtime + est. cost).
#' Finished-job runtimes feed the wall-time estimate of later plans.
#'
#' Source chain: ledger.R -> aws_api.R
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/cloud/helpers/aws_api.R")

LEDGER_EVENTS <- c("planned", "launched", "terminated", "finished")


utc_stamp <- function(time = Sys.time()) format(time, "%Y%m%dT%H%M%SZ", tz = "UTC")


#' Append one event to the local ledger and mirror it to S3.
#'
#' A failed S3 mirror is a warning, never an error (the local line is the record).
#' @param data Named list of extra fields (job ids, kind, runtime, cost, ...).
#' @return The record, invisibly.
ledger_append <- function(event, plan_id, data = list(), ledger_path = CLOUD_LEDGER, mirror = TRUE) {
  if (!event %in% LEDGER_EVENTS) stop(sprintf("Unknown ledger event: %s", event), call. = FALSE)
  now <- Sys.time()
  record <- c(list(ts = format(now, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"), event = event, plan_id = plan_id), data)
  line <- as.character(jsonlite::toJSON(record, auto_unbox = TRUE, null = "null", digits = NA))
  dir.create(dirname(ledger_path), recursive = TRUE, showWarnings = FALSE)
  cat(line, "\n", file = ledger_path, sep = "", append = TRUE)
  if (mirror) {
    key <- sprintf("ledger/%s/%s_%s_%s.json", format(now, "%Y-%m", tz = "UTC"), utc_stamp(now), plan_id, event)
    tmp <- tempfile("ledger_", fileext = ".json")
    on.exit(unlink(tmp), add = TRUE)
    writeLines(line, tmp)
    tryCatch(aws_s3_cp(normalizePath(tmp, winslash = "/"), s3_uri(key)),
             error = function(e) warning(sprintf("Ledger S3 mirror failed (local line kept): %s", conditionMessage(e)),
                                         call. = FALSE))
  }
  invisible(record)
}


#' All ledger records as a list of lists (empty list if no ledger yet).
ledger_read <- function(ledger_path = CLOUD_LEDGER) {
  if (!file.exists(ledger_path)) return(list())
  lines <- readLines(ledger_path, warn = FALSE)
  lapply(lines[nzchar(lines)], jsonlite::fromJSON, simplifyVector = TRUE)
}


#' Median runtime (hours) of successful finished jobs of a kind; NA if none.
ledger_median_hours <- function(kind, records = ledger_read()) {
  hours <- vapply(records, function(r) {
    if (identical(r$event, "finished") && identical(r$kind, kind) && identical(r$status, "SUCCEEDED")) {
      as.numeric(r$runtime_hours)
    } else NA_real_
  }, numeric(1))
  if (all(is.na(hours))) NA_real_ else stats::median(hours, na.rm = TRUE)
}


#' Job ids that already have a finished event (so status does not double-log).
ledger_finished_jobs <- function(records = ledger_read()) {
  unlist(lapply(records, function(r) if (identical(r$event, "finished")) r$job_id))
}
