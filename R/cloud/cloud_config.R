#' =============================================================================
#' Cloud (AWS Batch) wrapper constants. NON-SECRET values only: no account IDs,
#' ARNs, keys or tokens may ever appear in this file (the repo is public).
#'
#' Sourced by R/cloud/helpers/*.R and R/cloud/paf_aws.R.
#' =============================================================================

# --- Identity ----------------------------------------------------------------
AWS_PROFILE_NAME <- "paf-agent"
AWS_REGION       <- "us-east-1"
AWS_ROLE_PREFIX  <- "AWSReservedSSO_PafAgent_"

# --- Batch contract (shared with the container image) -------------------------
BATCH_QUEUE_SPOT     <- "paf-spot"
BATCH_QUEUE_ONDEMAND <- "paf-ondemand"
BATCH_JOB_DEFINITION <- "paf-job"
BATCH_LOG_GROUP      <- "/aws/batch/job"

# --- Storage -----------------------------------------------------------------
CLOUD_BUCKET_ROOT <- "jon-nir/paf-models"   # <bucket>/<prefix>

# --- Job kinds ---------------------------------------------------------------
# wall_hours: expected wall time of one job; NA = unknown until measured, then
# the median of finished jobs of that kind in the ledger is used.
# timeout_hours: hard Batch attempt timeout (the teardown guarantee).
CLOUD_KINDS <- data.frame(
  kind          = c("smoke",     "fit",        "resume",     "recovery",   "bf",         "ppc"),
  vcpu          = c(4L,          16L,          16L,          16L,          16L,          16L),
  memory_mib    = c(6000L,       28000L,       28000L,       28000L,       28000L,       28000L),
  instance_type = c("c5.xlarge", "c6a.4xlarge", "c6a.4xlarge", "c6a.4xlarge", "c6a.4xlarge", "c6a.4xlarge"),
  timeout_hours = c(0.5,         24,           24,           24,           12,           6),
  wall_hours    = c(0.25,        NA_real_,     NA_real_,     NA_real_,     NA_real_,     NA_real_),
  stringsAsFactors = FALSE
)
CLOUD_ALLOWED_KINDS <- CLOUD_KINDS$kind

# On-demand hourly USD (us-east-1, Linux); the agent role has no Pricing API access.
ONDEMAND_PRICE_USD_HR <- c("c6a.4xlarge" = 0.612, "c5.xlarge" = 0.17)

# Optional container env the caller may set (besides the wrapper-controlled ones).
CLOUD_OPTIONAL_ENV <- c("PT_PRIOR_SD_SCALE", "FIT_PREFIX", "FIT_DIR")

# --- Caps and budget ---------------------------------------------------------
MAX_CONCURRENT_VCPU <- 64L    # spot
ONDEMAND_MAX_VCPU   <- 16L
MONTHLY_BUDGET_USD  <- 50
COST_CACHE_HOURS    <- 6      # each Cost Explorer call costs USD 0.01

# --- Local state (gitignored) ------------------------------------------------
PLAN_TTL_MINUTES <- 30
CLOUD_STATE_DIR  <- ".paf-aws"
CLOUD_PLANS_DIR  <- file.path(CLOUD_STATE_DIR, "plans")
CLOUD_LEDGER     <- file.path(CLOUD_STATE_DIR, "ledger.jsonl")
CLOUD_CACHE_DIR  <- file.path(CLOUD_STATE_DIR, "cache")

# Accepted characters of every job argument token.
CLOUD_ARG_TOKEN_REGEX <- "^[A-Za-z0-9._/=-]+$"
