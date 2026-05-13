#' =============================================================================
#' Logging and String Utilities
#'
#' Pure I/O helpers with no dependencies on EMC2, data structures, or config.
#' Provides timestamped dual-target logging (console + file), structured error
#' reporting with stack traces, and config variable serialisation. All other
#' helper modules depend on this one; it is safe to source standalone.
#' =============================================================================


# -------------------------
#' Validate that a value is a non-empty, non-NA scalar string.
check_valid_string <- function(s) {
  !is.null(s) && length(s) == 1 && !is.na(s) && nzchar(s)
}


# -------------------------
#' Write a timestamped message to a log file, optionally echoing to console.
#' @param msg         Character string to log.
#' @param file_path   Path to the log file (appended to).
#' @param console_print Logical; if TRUE the message is also cat()-ed to stdout.
log_msg <- function(msg, file_path, console_print = FALSE) {
  if (!check_valid_string(file_path)) stop(sprintf("Invalid Log File Path: %s", file_path))
  timestamped_msg <- paste0("[", Sys.time(), "] :: ", msg, "\n")
  if (console_print) {
    cat(timestamped_msg)
  }
  cat(timestamped_msg, file = file_path, append = TRUE)
}


#' Source a config file into a private environment and log all variables.
#' @param config_path Path to the R config script to introspect.
#' @param log_file    Path to the log file (appended to).
log_config_variables <- function(config_path, log_file) {
  if (!check_valid_string(config_path)) stop(sprintf("Invalid Config Path: %s", config_path))
  if (!check_valid_string(log_file))    stop(sprintf("Invalid Log File Path: %s", log_file))

  cnfg_env <- new.env()
  source(config_path, local = cnfg_env)

  log_msg("--- SESSION CONFIGURATION ---", log_file, console_print = FALSE)
  for (v in ls(cnfg_env)) {
    val_str <- paste(get(v, envir = cnfg_env), collapse = ", ")
    log_msg(sprintf("  %-25s : %s", v, val_str), log_file, console_print = FALSE)
  }
  log_msg("------------------------------\n", log_file, console_print = FALSE)
}


#' Log a structured error with message, immediate call site, and full stack trace.
#' @param err      An error condition object (from tryCatch).
#' @param log_file Path to the log file (appended to).
#' @param context  Optional string identifying where the error occurred.
log_error <- function(err, log_file, context = "") {
  failed_call <- paste(deparse(conditionCall(err)), collapse = "\n")
  stack_trace <- paste(
    lapply(sys.calls(), function(x) paste(deparse(x), collapse = "\n")),
    collapse = "\n  -> "
  )
  err_msg <- sprintf(
    "FAILED [%s]\n  Error Message: %s\n  Immediate Call: %s\n  Full Stack Trace:\n  %s",
    context, err$message, failed_call, stack_trace
  )
  log_msg(err_msg, log_file, console_print = TRUE)
}
