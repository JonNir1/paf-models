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

source("R/config.R")


# ---------------------
# Load the model
MODEL_NAME = "260412_model5"
MODEL <- readRDS(file.path(MODELS_DIR, MODEL_NAME))


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
