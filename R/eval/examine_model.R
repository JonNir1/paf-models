# ==============================================================================
# --- PAF Project: Model Examination ---
# This is a light-weight script for examining an EMC2::model object, focusing
# on convergence stats (the `check()` call) and evaluated parameters (the
# `credint()` call).
# Note the `credint()` funciton takes `mu`/`sigma2`/`alpha`/`correlation` or
# other options as argument for the type of evaluated parameter to display.
# ==============================================================================

# Load Core Configurations and Helpers
library(EMC2)

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/eval/eval_config.R")    # transitively: utils.R -> config.R
source_root("R/eval/helpers/io.R")     # load_model, discover_model_names (via eval_config)


# ---------------------
# Load a model (latest-dated fit). Set MODEL_NAME to inspect a specific one;
# defaults to the first model discovered in MODELS_FIT_DIR.
MODEL_NAME <- discover_model_names()[1]
if (is.na(MODEL_NAME))
  stop(sprintf("No fitted models found in %s.", MODELS_FIT_DIR))
MODEL <- load_model(MODEL_NAME, MODELS_FIT_DIR)


# ---------------------
# # Extract underlying objects
# data <- environment(MODEL[[1]][["model"]])[["data"]]
# design <- environment(MODEL[[1]][["model"]])[["design"]]
# prior <- MODEL[[1]][["prior"]]


# ---------------------
# Run diagnostics
# check model convergence
check(MODEL)

# TODO: add more diagnostics!


# Analyze results
# ---------------------
# extract parameter values
credint(MODEL, selection="mu", digits=2, probs=c(0.025, 0.5, 0.975))

# TODO: add analyses!
# TODO: plot posterior predictive distributions
