#' =============================================================================
#' Project-level utilities. Loaded first by every R script.
#'
#' Provides:
#'   source_root(rel)   - source a file relative to PAF_REPO_ROOT (or cwd)
#'   parse_int_arg()    - parse `--flag N` from a CLI args vector (NULL if absent)
#'   parse_str_arg()    - parse `--flag value` from a CLI args vector (NULL if absent)
#'   check_valid_string - TRUE iff s is a non-empty, non-NA scalar character
#'
#' Usage (at the top of every script):
#'   source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
#'   source_root("R/config.R")
#' =============================================================================


#' Source an R file using a path relative to the repo root.
#' Repo root is taken from the PAF_REPO_ROOT environment variable if set,
#' otherwise the current working directory. This replaces the repeated
#' local({ root <- Sys.getenv("PAF_REPO_ROOT", ...) ... }) block.
source_root <- function(rel_path) {
  root <- Sys.getenv("PAF_REPO_ROOT", unset = "")
  base <- if (nzchar(root)) root else getwd()
  source(file.path(base, rel_path))
}


#' Parse `--flag N` from a CLI argument vector. Returns NULL if absent.
parse_int_arg <- function(args, flag) {
  idx <- which(args == flag)
  if (length(idx) > 0L && idx[[1L]] < length(args)) as.integer(args[[idx[[1L]] + 1L]]) else NULL
}


#' Parse `--flag value` from a CLI argument vector. Returns NULL if absent.
parse_str_arg <- function(args, flag) {
  idx <- which(args == flag)
  if (length(idx) > 0L && idx[[1L]] < length(args)) args[[idx[[1L]] + 1L]] else NULL
}


#' TRUE iff s is a non-NULL, non-NA, length-1 character with nchar > 0.
check_valid_string <- function(s) {
  !is.null(s) && length(s) == 1 && !is.na(s) && nzchar(s)
}
