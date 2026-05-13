#' =============================================================================
#' Generate __tests__/fixtures/sample_data.csv
#'
#' Synthetic EMC2 design matrix that mirrors the structure of
#' data/emc2_design_matrix.csv. No real participant data; safe to commit.
#'
#' Output: 2 subjects x 30 trials x 4 accumulators = 240 rows.
#' Covers: all search_difficulty levels, all cue_size levels, both
#' experiments, and a mix of repeated / non-repeated targets.
#'
#' Run from repo root:
#'   Rscript __tests__/fixtures/generate_fixture.R
#' =============================================================================

set.seed(42)

N_SUBJECTS  <- 2
N_TRIALS    <- 30   # per subject
N_ACC       <- 4    # accumulators (locations)

# --- Trial-level distributions -------------------------------------------
difficulties <- rep(c("EASY", "MIXED", "DIFFICULT"), length.out = N_TRIALS)
cue_sizes    <- rep(c("NONE", "SMALL", "MEDIUM", "LARGE"), length.out = N_TRIALS)
experiments  <- rep(c("exp_1", "exp_2"), length.out = N_TRIALS)

# Build S string: "T,D,E,E" etc. with T always at target_location.
make_S <- function(target_loc, difficulty) {
  fillers <- switch(difficulty,
    EASY      = rep("E", 3),
    DIFFICULT = rep("D", 3),
    MIXED     = c("D", "E", "E")
  )
  slots <- character(4)
  slots[target_loc] <- "T"
  slots[-target_loc] <- fillers
  paste(slots, collapse = ",")
}

rows <- vector("list", N_SUBJECTS * N_TRIALS * N_ACC)
row_idx <- 1L

for (sub in seq_len(N_SUBJECTS)) {
  prev_target <- sample(1:4, 1)

  for (trial in seq_len(N_TRIALS)) {
    target_loc  <- sample(1:4, 1)
    cue_loc     <- sample(1:4, 1)
    cue_size    <- cue_sizes[trial]
    difficulty  <- difficulties[trial]
    experiment  <- experiments[trial]
    is_repeat   <- (target_loc == prev_target)
    S           <- make_S(target_loc, difficulty)

    # RT: slightly faster when target is cued
    base_rt <- runif(1, 0.28, 0.90)
    rt      <- if (cue_loc == target_loc) base_rt * 0.85 else base_rt
    rt      <- round(rt, 4)

    # Response: target location wins most of the time (p=0.75)
    R <- if (runif(1) < 0.75) target_loc else sample(setdiff(1:4, target_loc), 1)

    for (lR in 1:N_ACC) {
      rows[[row_idx]] <- list(
        subjects             = sub,
        rt                   = rt,
        R                    = R,
        S                    = S,
        lR                   = lR,
        cue_location         = cue_loc,
        target_location      = target_loc,
        prev_target_location = prev_target,
        cue_size             = cue_size,
        search_difficulty    = difficulty,
        is_target_repeated   = is_repeat,
        experiment           = experiment
      )
      row_idx <- row_idx + 1L
    }

    prev_target <- target_loc
  }
}

df <- do.call(rbind, lapply(rows, as.data.frame, stringsAsFactors = FALSE))

out_path <- "__tests__/fixtures/sample_data.csv"
write.csv(df, out_path, row.names = FALSE)
message(sprintf("Written %d rows to %s", nrow(df), out_path))
