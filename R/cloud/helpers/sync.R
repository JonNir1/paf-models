#' =============================================================================
#' Moving results between S3 and the local MAIN checkout.
#'
#'   sync_results(kind)  : S3 results/<kind>/ -> outputs/... of the main checkout
#'   promote_fits()      : latest-dated results/fit/YYMMDD_<model>.rds per model
#'                         -> inputs/fit/ (the resume/recovery/ppc/bf inputs)
#'
#' Neither ever overwrites an existing file; both skip it and say so.
#'
#' Source chain: sync.R -> aws_api.R
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/cloud/helpers/aws_api.R")

# kind -> S3 prefix and local destination (relative to the main checkout).
SYNC_TARGETS <- list(
  fit      = list(prefix = "results/fit/",      dir = "outputs/models/fit"),
  resume   = list(prefix = "results/fit/",      dir = "outputs/models/fit"),
  recovery = list(prefix = "results/recovery/", dir = "outputs/models/fit_recovery"),
  bf       = list(prefix = "results/bf/",       dir = "outputs/models/fit_bf"),
  ppc      = list(prefix = "results/ppc/",      dir = "outputs/models/fit_ppc"),
  smoke    = list(prefix = "results/smoke/",    dir = "outputs/smoke"),
  logs     = list(prefix = "results/logs/",     dir = "outputs/logs")
)

SENSITIVITY_PATTERN <- "_sd(?![A-Za-z])"


#' Path of the main checkout (first entry of `git worktree list`).
main_checkout_root <- function() {
  out <- suppressWarnings(system2("git", c("-C", shQuote(Sys.getenv("PAF_REPO_ROOT", getwd())), "worktree", "list", "--porcelain"),
                                  stdout = TRUE, stderr = FALSE))
  first <- grep("^worktree ", out, value = TRUE)[1]
  if (is.na(first)) stop("Could not resolve the main checkout from `git worktree list`", call. = FALSE)
  sub("^worktree ", "", first)
}


#' Download everything under a kind's S3 prefix into the main checkout, skipping existing files.
#' @return data.frame(file, status) with status "downloaded" or "exists".
sync_results <- function(kind, root = main_checkout_root()) {
  target <- SYNC_TARGETS[[kind]]
  if (is.null(target)) stop(sprintf("Unknown sync kind '%s' (allowed: %s)", kind, paste(names(SYNC_TARGETS), collapse = ", ")), call. = FALSE)
  listing <- aws_s3_ls(target$prefix)
  rel <- sub(paste0("^", target$prefix), "", listing$key)
  keep <- nzchar(rel) & !endsWith(rel, "/")
  listing <- listing[keep, , drop = FALSE]
  rel <- rel[keep]
  status <- character(length(rel))
  for (i in seq_along(rel)) {
    parts <- strsplit(rel[[i]], "/", fixed = TRUE)[[1]]
    if (!all(grepl(CLOUD_ARG_TOKEN_REGEX, parts)) || any(parts == "..")) {
      stop(sprintf("Refusing unsafe S3 object name: '%s'", rel[[i]]), call. = FALSE)
    }
    local <- file.path(root, target$dir, rel[[i]])
    if (file.exists(local)) {
      status[[i]] <- "exists"
      next
    }
    dir.create(dirname(local), recursive = TRUE, showWarnings = FALSE)
    aws_s3_cp(s3_uri(listing$key[[i]]), normalizePath(local, winslash = "/", mustWork = FALSE))
    status[[i]] <- "downloaded"
  }
  data.frame(file = rel, status = status, stringsAsFactors = FALSE)
}


#' Latest-dated fit file per model from `YYMMDD_<model>[_extended].rds` names.
#'
#' Sensitivity fits (`_sd` in the model name) are dropped unless requested.
#' @param keys Character vector of file names.
#' @return The selected names, ordered by model. Stops on a same-date tie.
select_latest_per_model <- function(keys, include_sensitivity = FALSE) {
  keys <- keys[grepl("^[0-9]{6}_.+\\.rds$", keys)]
  model <- sub("(_extended)+$", "", sub("^[0-9]{6}_", "", sub("\\.rds$", "", keys)))
  if (!include_sensitivity) {
    keep <- !grepl(SENSITIVITY_PATTERN, model, perl = TRUE)
    keys <- keys[keep]
    model <- model[keep]
  }
  date <- substr(keys, 1L, 6L)
  chosen <- character(0)
  for (m in sort(unique(model))) {
    in_m <- model == m
    newest <- max(date[in_m])
    hit <- keys[in_m & date == newest]
    if (length(hit) > 1L) {
      stop(sprintf("Ambiguous latest fit for '%s': %s. Remove or rename one.", m, paste(hit, collapse = ", ")), call. = FALSE)
    }
    chosen <- c(chosen, hit)
  }
  chosen
}


#' Copy the latest fit per model from results/fit/ to inputs/fit/ inside the bucket.
#' @return data.frame(file, status) with status "promoted" or "exists".
promote_fits <- function(include_sensitivity = FALSE) {
  results <- aws_s3_ls("results/fit/")
  flat <- sub("^results/fit/", "", results$key)
  flat <- flat[nzchar(flat) & !grepl("/", flat, fixed = TRUE)]
  chosen <- select_latest_per_model(flat, include_sensitivity)
  existing <- sub("^inputs/fit/", "", aws_s3_ls("inputs/fit/")$key)
  status <- character(length(chosen))
  for (i in seq_along(chosen)) {
    if (chosen[[i]] %in% existing) {
      status[[i]] <- "exists"
      next
    }
    aws_s3_cp(s3_uri(paste0("results/fit/", chosen[[i]])), s3_uri(paste0("inputs/fit/", chosen[[i]])))
    status[[i]] <- "promoted"
  }
  data.frame(file = chosen, status = status, stringsAsFactors = FALSE)
}
