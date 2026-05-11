#' =============================================================================
#' --- Extend Model Fitting ---
#' This script operates on previously-fit models, and extends their fitting
#' until all models reach sufficient convergence criteria. These criteria can be
#' a predefined number of samples; a maximal value of R-hat; or minimal ESS value.
#' Note that this script SHOULD RUN AFTER running the `inital_fit.R` script that
#' fits each model for 1k samples regardless of convergence measures.
#' =============================================================================

# Load Core Configurations and Helpers
library(EMC2)

source("R/config.R")
source(file.path(CODE_DIR, "model_fitting", "helpers.R"))


# Setup Global Reproducibility
RNGkind(RNG_KIND)
set.seed(RNG_SEED)


# Setup Model Queue
## IMPORTANT! SET THESE UP MANUALLY ##
model_files <- c(
  "260421_model1.rds",
  "260409_model2.rds",
  "260424_model4.rds",
  "260412_model5.rds"
)


# Initialize Session Logging
log_msg("===== STARTING EXTENDED-FITTING SESSION =====\n", LOG_FILE, console_print = TRUE)
log_msg(paste("Loading models from ", MODELS_DIR), LOG_FILE, console_print = TRUE)
log_msg(
  sprintf("Configuration: MAX_RHAT=%s, MIN_ESS=%s, MIN_NUM_SAMPLES=%s", MAX_RHAT, MIN_ESS, MIN_NUM_SAMPLES),
  LOG_FILE,
  console_print = TRUE
)
log_msg("------------------------------\n", LOG_FILE, console_print = FALSE)


# Execution Loop
for (mf in model_files) {
  start_time <- Sys.time()
  log_msg("===========================================", LOG_FILE, console_print = TRUE)
  
  status <- tryCatch({
    full_path <- file.path(MODELS_DIR, mf)
    log_msg(paste("Model Path:\t", full_path), LOG_FILE, console_print = TRUE)
    model <- readRDS(full_path)
    
    # Extend the Fit
    model_ext <- run_emc(
      model,
      stage="sample",
      stop_criteria=list(max_gr=MAX_RHAT, min_es=MIN_ESS, iter=MIN_NUM_SAMPLES),
      max_tries=MAX_TRIES,
      step_size=STEP_SIZE,
      cores_for_chains = NUM_CORES
      )
    
    # save model
    orig_model_name <- sub("^[0-9]{6}_", "", tools::file_path_sans_ext(mf))
    ext_model_name <- paste0(model_name_base, "_extended")
    saved_path <- save_model(fitted_model, ext_model_name, MODELS_DIR)
    log_msg(paste("Successfully saved to:", saved_path), LOG_FILE, console_print = TRUE)
    
    "COMPLETE"
    
  }, error = function(e) {
    log_error(e)
    return("ERROR")
  })
  
  # log and clear memory
  end_time <- Sys.time()
  duration <- difftime(end_time, start_time, units = "mins")
  log_msg(
    paste("Finished extending", mf, "in", round(duration, 2), "minutes. Status:", status, "\n\n"),
    LOG_FILE,
    console_print = TRUE
  )
  rm(model, model_ext, start_time, end_time, duration)
  try(parallel::stopCluster(cl = NULL), silent = TRUE)  # force-release socket ports
  Sys.sleep(5)  # hopefully this is enough to avoid TIME_WAIT errors for closed sockets
  gc()
}

