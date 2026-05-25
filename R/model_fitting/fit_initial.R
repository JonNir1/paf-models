# ==============================================================================
# --- PAF Project: Master Model-Fitting Script ---
# This script is used for the initial fitting of the 5 EMC2 models we evaluate
# against the PAF dataset. Each model is fit to the same dataset over 1k samples
# ==============================================================================

# Load Core Configurations and Helpers
library(EMC2)

source("R/config.R")
source(file.path(CODE_DIR, "model_fitting", "helpers", "fitting.R"))

# Setup Global Reproducibility
RNGkind(RNG_KIND)
set.seed(RNG_SEED)

# Initialize Session Logging
log_msg("===== STARTING NEW BATCH FITTING SESSION =====\n", LOG_FILE, console_print = TRUE)
log_config_variables(CONFIG_FILE, LOG_FILE)

# Data Pipeline (Load and Filter ONCE) - using variables defined in config.R
log_msg(paste("Loading data from file", DATA_FILE), LOG_FILE, console_print = TRUE)
raw_data <- load_safe_csv(DATA_FILE)

clean_data <- filter_data(
  raw_data, 
  min_rt = MIN_SACCADE_CUTOFF, 
  max_rt = MAX_SACCADE_CUTOFF,
  allow_target_repeats = ALLOW_TARGET_REPEAT
)
log_msg(
  sprintf("Data Summary: Loaded %d lines from %d unique subjects", 
          nrow(clean_data), n_distinct(clean_data$sub)), 
  LOG_FILE, console_print = TRUE
)

excluded_count <- nrow(raw_data) - nrow(clean_data)
log_msg(
  sprintf("Exclusion: Removed %d trials (%.1f%%) based on RT cutoffs [%.2f, %.2f]", 
          excluded_count, (excluded_count/nrow(raw_data))*100, 
          MIN_SACCADE_CUTOFF, MAX_SACCADE_CUTOFF), 
  LOG_FILE, console_print = TRUE
)
log_msg("------------------------------\n", LOG_FILE, console_print = FALSE)

# Define Model Queue
log_msg("--- INITIALIZING MODEL FITTING ---\n", LOG_FILE, console_print = TRUE)
model_files <- c(
  "model1.R",
  "model2.R",
  "model3.R",
  "model4.R",
  "model5.R"
)

# Execution Loop
for (script in model_files) {

  start_time <- Sys.time()
  log_msg("===========================================", LOG_FILE, console_print = TRUE)
  log_msg(paste("Processing Script:", script), LOG_FILE, console_print = TRUE)

  # Source the script to get the build_model() function and MODEL_NAME
  # Wrapped in tryCatch to prevent one broken script from stopping the whole batch
  status <- tryCatch({

    source(file.path(CODE_DIR, "model_fitting", script))
    log_msg(paste("Model Name:\t", MODEL_NAME), LOG_FILE, console_print = TRUE)
    
    # Generate the EMC2 model object
    current_model <- build_model(clean_data, n_chains = N_CHAINS)

    # --- Capture and Log Model Formulas ---
    design_obj <- environment(current_model[[1]][["model"]])$design
    formula_text <- paste(design_obj[[1]], collapse = "\n")
    log_msg(paste0("Model Formulas:\n", formula_text, "\n"), LOG_FILE, console_print = TRUE)

    # --- Capture and Log Model's Mapped Parameters ---
    # This turns the printed table into a string for the log file:
    mapping_table <- capture.output(mapped_pars(design_obj))
    mapping_text  <- paste(mapping_table, collapse = "\n")
    log_msg(paste0("Parameter Mapping:\n", mapping_text, "\n"), LOG_FILE, console_print = TRUE)

    # --- Execute Fit ---
    core_args <- get_core_args(N_CHAINS)
    log_msg(
      sprintf("Fitting %s: n_chains=%d, cores_for_chains=%d, cores_per_chain=%d (machine has %d cores)",
              MODEL_NAME, N_CHAINS,
              core_args$cores_for_chains, core_args$cores_per_chain,
              parallel::detectCores()),
      LOG_FILE, console_print = TRUE
    )
    fitted_model <- fit(  # fit() will run until convergence or max_iter
      current_model,
      cores_for_chains = core_args$cores_for_chains,
      cores_per_chain  = core_args$cores_per_chain,
      iter=MIN_NUM_SAMPLES,                 # used in prod
      # iter=5, max_tries=2, step_size=10,    # used for testing the pipeline
      )
    
    # --- Save Result ---
    saved_path <- save_model(fitted_model, MODEL_NAME, MODELS_INITIAL_DIR)
    log_msg(paste("Successfully saved to:", saved_path), LOG_FILE, console_print = TRUE)
    
    "COMPLETE"
    
  }, error = function(e) {
    log_error(e)
    return("ERROR")
  })
  
  # Post-Model Cleanup
  end_time <- Sys.time()
  duration <- difftime(end_time, start_time, units = "mins")
  log_msg(
    paste("Finished", script, "in", round(duration, 2), "minutes. Status:", status, "\n\n"),
    LOG_FILE,
    console_print = TRUE
  )
  
  # Explicitly clear memory to keep the RAM fresh for the next model
  rm(
    current_model, design_obj, formula_text, mapping_table, mapping_text,
    fitted_model, MODEL_NAME, start_time, end_time, duration
  )
  try(parallel::stopCluster(cl = NULL), silent = TRUE)  # force-release socket ports
  Sys.sleep(5)  # hopefully this is enough to avoid TIME_WAIT errors for closed sockets
  gc()
}

log_msg("===== BATCH FITTING SESSION ENDED =====", LOG_FILE, console_print = TRUE)
