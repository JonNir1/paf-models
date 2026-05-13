#' =============================================================================
#' Shared assertion helpers for build_model() tests (level 2).
#'
#' Imported at the top of test_build_models.R. Each function wraps one or more
#' testthat expect_* calls so individual model tests stay concise.
#' =============================================================================


#' Assert that `model` is a structurally valid emc object with `n_chains` chains.
expect_valid_emc <- function(model, n_chains, label = "") {
  label <- if (nzchar(label)) paste0(" [", label, "]") else ""
  expect_type(model, "list",
    label = paste0("model is a list", label))
  expect_length(model, n_chains,
    label = paste0("model has ", n_chains, " chains", label))
  for (i in seq_len(n_chains)) {
    expect_type(model[[i]], "list",
      label = paste0("chain ", i, " is a list", label))
  }
}


#' Extract the EMC2 design object from a fitted/built emc model.
.get_design <- function(model) {
  environment(model[[1]][["model"]])$design
}


#' Assert that the formula RHS for `param` matches `expected_rhs`.
#' `expected_rhs` is compared to the deparsed RHS of the extracted formula.
expect_formula_rhs <- function(model, param, expected_rhs, label = "") {
  label   <- if (nzchar(label)) paste0(" [", label, "]") else ""
  design  <- .get_design(model)
  formulas <- design[[1]]  # list of formula objects
  # find the formula whose LHS matches `param`
  lhs_match <- vapply(formulas, function(f) {
    tryCatch(deparse(f[[2]]) == param, error = function(e) FALSE)
  }, logical(1))
  if (!any(lhs_match)) {
    fail(sprintf("No formula with LHS '%s' found in design%s", param, label))
    return(invisible(NULL))
  }
  actual_rhs <- deparse(formulas[lhs_match][[1]][[3]])
  expect_equal(actual_rhs, expected_rhs,
    label = paste0("formula RHS for '", param, "'", label))
}


#' Assert that the sorted parameter names of `model` equal `expected_names`.
#' Uses mapped_pars() to extract parameter names from the design object.
expect_param_names <- function(model, expected_names, label = "") {
  label  <- if (nzchar(label)) paste0(" [", label, "]") else ""
  design <- .get_design(model)
  # mapped_pars() prints a table; capture names from the design's p_map
  actual <- sort(rownames(mapped_pars(design)))
  expect_setequal(actual, sort(expected_names),
    label = paste0("parameter names", label))
}


#' Assert that the prior mean for `param_name` equals `expected_value`.
expect_prior_mean <- function(model, param_name, expected_value,
                               tol = 1e-9, label = "") {
  label    <- if (nzchar(label)) paste0(" [", label, "]") else ""
  design   <- .get_design(model)
  prior_mu <- environment(model[[1]][["model"]])$prior$mu_mean
  expect_true(param_name %in% names(prior_mu),
    label = paste0("prior_mu contains '", param_name, "'", label))
  expect_equal(unname(prior_mu[[param_name]]), expected_value,
    tolerance = tol,
    label = paste0("prior mean for '", param_name, "'", label))
}
