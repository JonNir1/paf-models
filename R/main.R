library(EMC2)

source("R/handle_data.R")
source("R/emc2_helpers.R")

# set random seed
RNGkind("L'Ecuyer-CMRG")
set.seed(123456)

# set model name
MODEL_NAME <- "lba_distractor_searchdiff_cue"

# Set Constants
# ---------------------
DATA_FILE <- "data/emc2_design_matrix.csv"
MIN_SACCADE_CUTOFF <- 0.23
MAX_SACCADE_CUTOFF <- 1.0
ALLOW_TARGET_REPEAT <- FALSE


# Load Data
# ---------------------
data <- load_safe_csv(DATA_FILE)
clean_data <- filter_data(
  data,
  min_rt=MIN_SACCADE_CUTOFF,
  max_rt=MAX_SACCADE_CUTOFF,
  allow_target_repeats=ALLOW_TARGET_REPEAT
)

# keep only the columns we actually use
clean_data <- clean_data %>% 
  select(
    subjects, rt, R, S,
    cue_location, cue_size,
    # prev_target_location,
    # is_cue_at_prev_target,  # we can extract this with a model-function
    # target_location,        # we don't really need this column, ever
    )
clean_data <- as.data.frame(clean_data)

# # Subset the data for checking model validity
# unique_subjs <- unique(clean_data$subjects)
# subset_subjs <- unique_subjs[1:3]
# clean_subset <- clean_data[clean_data$subjects %in% subset_subjs, ]


# Build EMC2.Design
# ---------------------
LBA_design <- design(
  data=clean_data,
  model=LBA,
  functions=list(
    DistractorAtLoc=DistractorAtLoc,
    SearchDifficulty=SearchDifficulty,
    CueAtLoc=CueAtLoc
    ),
  # contrasts=list(),
  formula=list(
    v ~ DistractorAtLoc * CueAtLoc,
    sv ~ DistractorAtLoc,
    B ~ SearchDifficulty,
    A ~ 1,
    t0 ~ 1
  ),
  constants=c(sv=log(1)),
)
mapped_pars(LBA_design)


# Specify EMC2.Priors
# ---------------------
# prior means
mu_mean <- c(
  
  # v (drift rates) is on the real line
  v = 2,                        # baseline drift: distractor=Target; cuesize=NONE
  v_DistractorAtLocD = -0.5,    # Hard distractors compete with target
  v_DistractorAtLocE = -1,      # Easy distractors reduce attention but may still get some (so not 0!)
  v_CueAtLocSMALL = 0.5,        # Small cuesize increases attention, slightly
  v_CueAtLocLARGE = 1,          # Large cuesize increases attention, more than Small
  
  "v_DistractorAtLocD:CueAtLocSMALL" = 0,       # no interaction for Hard distractor × Small cue
  "v_DistractorAtLocE:CueAtLocSMALL" = 0,       # no interaction for Easy distractor × Small cue
  "v_DistractorAtLocD:CueAtLocLARGE" = 0.25,    # large gain for interaction Hard distractor × Large cue
  "v_DistractorAtLocE:CueAtLocLARGE" = 0.1,     # small gain for interaction Easy distractor × Large cue
  
  # sv is in log scale
  sv_DistractorAtLocE = log(1),    # same variability for Target and Easy distractors
  sv_DistractorAtLocD = log(1),    # same variability for Target and Hard distractors
  
  # B, A, t0 are in log scale
  B = log(1),                              # Baseline caution for SearchDifficulty=="EASY"
  B_SearchDifficultyMIXED = log(1.5),      # Increased caution for SearchDifficulty=="MIXED"
  B_SearchDifficultyDIFFICULT = log(2),    # Highest caution for SearchDifficulty=="DIFFICULT"
  
  A = log(0.25),
  
  t0 = log(0.2)
)

# prior uncertainties
mu_sd <- c(
  v = 1,
  v_DistractorAtLocE = 1, v_DistractorAtLocD = 1,
  v_CueAtLocSMALL = 1, v_CueAtLocLARGE = 1,
  "v_DistractorAtLocD:CueAtLocSMALL" = 0.25,
  "v_DistractorAtLocE:CueAtLocSMALL" = 0.25,
  "v_DistractorAtLocD:CueAtLocLARGE" = 0.25,
  "v_DistractorAtLocE:CueAtLocLARGE" = 0.25,
  
  sv_DistractorAtLocE = 0.5, sv_DistractorAtLocD = 0.5,
  
  B = 0.3, B_SearchDifficultyMIXED = 0.3, B_SearchDifficultyDIFFICULT = 0.3,
  
  A = 0.4,
  t0 = 0.4
)

# prior object
LBA_prior <- prior(
  LBA_design,
  type = 'standard',
  mu_mean=mu_mean,
  mu_sd=mu_sd
)
# plot(LBA_prior)


# Fit EMC2 Object
# ---------------------
LBA_model <- make_emc(clean_data, design = LBA_design, prior = LBA_prior)
LBA_model <- fit(LBA_model, cores_for_chains = 8)


# Run diagnostics
# ---------------------
# check model convergence
check(LBA_model)

# TODO: add more diagnostics!


# Save results to File
# Note: EMC2 model objects store in memory the prior() and design(), so no need to save those
# ---------------------
today <- format(Sys.Date(), "%y%m%d")
file_name <- paste0(today, "_", MODEL_NAME, ".rds")
saveRDS(LBA_model, file_name)


# Load saved model to verify integrity
# ---------------------
lba_loaded <- readRDS(file_name)


# Analyze results
# ---------------------
# extract parameter values
credint(LBA_model, selection="mu", digits=2, probs=c(0.025, 0.5, 0.975))

# TODO: add analyses!
# TODO: plot posterior predictive distributions
