#' =============================================================================
#' Project-level utilities. Loaded first by every R script.
#'
#' Provides:
#'   source_root(rel)   - source a file relative to PAF_REPO_ROOT (or cwd)
#'   parse_int_arg()    - parse `--flag N` from a CLI args vector (NULL if absent)
#'   parse_str_arg()    - parse `--flag value` from a CLI args vector (NULL if absent)
#'   check_valid_string - TRUE iff s is a non-empty, non-NA scalar character
#'   read_top_level()   - value of a script's top-level assignment, read without executing it
#'   find_model_script()- locate a model script by its declared MODEL_NAME (any file name)
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


#' Value of a script's top-level `name <- rhs` / `name = rhs`, read without
#' executing the script.
#'
#' Only the right-hand side is evaluated, in a fresh environment whose parent is
#' `baseenv()`, so it must be self-contained (a literal or base-R expression).
#'
#' @param exprs Parsed expressions, e.g. `parse(path, keep.source = FALSE)`.
#' @param name  Assigned symbol to look for.
#' @param fail  Called with a message on a repeated assignment or a failing
#'   right-hand side (default `stop`).
#' @return `list(value = <value>)`, or NULL if `name` is not assigned at top level.
read_top_level <- function(exprs, name, fail = stop) {
  rhs <- top_level_rhs(exprs, name)
  if (length(rhs) > 1L) fail(sprintf("%s is assigned more than once at top level (ambiguous declaration)", name))
  if (length(rhs) == 0L) return(NULL)
  value <- tryCatch(eval(rhs[[1]], new.env(parent = baseenv())),
                    error = function(e) fail(sprintf("right-hand side of %s failed to evaluate (%s); it must be self-contained",
                                                     name, conditionMessage(e))))
  list(value = value)
}


#' Right-hand sides (unevaluated) of every top-level assignment to `name`.
top_level_rhs <- function(exprs, name) {
  rhs <- list()
  for (ex in exprs) {
    if (is.call(ex) && (identical(ex[[1]], quote(`<-`)) || identical(ex[[1]], quote(`=`))) &&
        identical(ex[[2]], as.name(name))) rhs <- c(rhs, list(ex[[3]]))
  }
  rhs
}


#' Find a model's script by its declared `MODEL_NAME`, whatever the file is called.
#'
#' Parses (never executes) every `*.R` directly in `script_dir` and reads each
#' file's top-level `MODEL_NAME`. Files without a top-level `MODEL_NAME`, or
#' whose right-hand side is not a self-contained length-1 string (e.g.
#' `fit_cloud.R`, `fit_config.R`), are not model scripts and are skipped. A file
#' that cannot be parsed is also skipped (an unrelated broken file must not block
#' every lookup), but if no script matches, the error lists the unparsable files
#' so a broken model script never reads as a bare "not found". A script that
#' assigns `MODEL_NAME` more than once is an error (ambiguous declaration).
#' Names must be unique within `script_dir`.
#'
#' @param model_name Declared `MODEL_NAME` to look for.
#' @param script_dir Directory holding the model scripts.
#' @return Path of the one script declaring `model_name`.
find_model_script <- function(model_name, script_dir) {
  if (!dir.exists(script_dir)) stop(sprintf("Model script directory not found: %s", script_dir), call. = FALSE)
  files <- list.files(script_dir, pattern = "[.]R$", full.names = TRUE)
  declared <- character(0)
  unparsable <- character(0)
  for (f in files) {
    exprs <- tryCatch(parse(f, keep.source = FALSE),
                      error = function(e) NULL)
    if (is.null(exprs)) {
      unparsable <- c(unparsable, basename(f))
      next
    }
    rhs <- top_level_rhs(exprs, "MODEL_NAME")
    if (length(rhs) > 1L) {
      stop(sprintf("%s: MODEL_NAME is assigned more than once at top level (ambiguous declaration)", f), call. = FALSE)
    }
    value <- if (length(rhs) == 1L) tryCatch(eval(rhs[[1]], new.env(parent = baseenv())), error = function(e) NULL)
    if (check_valid_string(value) && is.character(value)) declared[f] <- value
  }

  hits <- names(declared)[declared == model_name]
  if (length(hits) == 1L) return(hits)
  if (length(hits) > 1L) {
    stop(sprintf("MODEL_NAME '%s' is declared by more than one script in '%s': %s (names must be unique within the script directory)",
                 model_name, script_dir, paste(basename(hits), collapse = ", ")), call. = FALSE)
  }
  stop(sprintf("No model script in '%s' declares MODEL_NAME '%s'. Model names found: %s.%s",
               script_dir, model_name,
               if (length(declared)) paste(sort(unname(declared)), collapse = ", ") else "(none)",
               if (length(unparsable)) sprintf(" Files that cannot be parsed (one may be the model script): %s.",
                                               paste(unparsable, collapse = ", ")) else ""),
       call. = FALSE)
}
