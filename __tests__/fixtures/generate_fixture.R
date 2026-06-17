#' =============================================================================
#' Generate __tests__/fixtures/sample_data.csv
#'
#' Synthetic EMC2-ready matrix that matches the output contract of
#' load_data() (R/helpers/data.R): the same 15 columns, in the same order,
#' ONE ROW PER TRIAL. EMC2::design() does the per-accumulator (lR) expansion
#' itself, so the fixture must NOT be pre-expanded. No real participant data;
#' safe to commit.
#'
#' Columns (load_data() order):
#'   experiment, subjects, block, trial_in_block, trials, rt, R, S,
#'   search_difficulty, target_location, cue_location, cue_size,
#'   is_target_repeated, is_cue_at_prev_target, prev_target_location
#'
#' Output: 2 subjects x 60 trials = 120 rows (one per trial).
#' Covers: all search_difficulty levels (EASY/MIXED/DIFFICULT), all cue sizes
#' (SMALL/MEDIUM/LARGE), both experiments, all 4 response locations, and a mix
#' of repeated / non-repeated targets.
#'
#' Run from repo root:
#'   Rscript __tests__/fixtures/generate_fixture.R
#' =============================================================================

set.seed(42)

N_SUBJECTS    <- 2
N_TRIALS      <- 60   # per subject
N_BLOCKS      <- 4    # per subject
N_LOC         <- 4    # response/stimulus locations

# Build the S string: one letter per location (1..4), comma-separated, with T
# at target_loc. Filler pattern is fixed by difficulty so that SearchDifficulty()
# (R/helpers/data.R) can classify it: EASY=3E, DIFFICULT=3D, MIXED=1D+2E.
make_S <- function(target_loc, difficulty) {
  fillers <- switch(difficulty,
    EASY      = rep("E", 3),
    DIFFICULT = rep("D", 3),
    MIXED     = c("D", "E", "E")
  )
  slots <- character(N_LOC)
  slots[target_loc]  <- "T"
  slots[-target_loc] <- fillers
  paste(slots, collapse = ",")
}

rows <- vector("list", N_SUBJECTS * N_TRIALS)
row_idx <- 1L

for (sub in seq_len(N_SUBJECTS)) {
  prev_target <- sample(seq_len(N_LOC), 1)

  for (trial in seq_len(N_TRIALS)) {
    # Deterministic cycling guarantees full coverage of difficulty and target
    # location (hence all 4 R levels -> 4 accumulators in design()).
    difficulty  <- c("EASY", "MIXED", "DIFFICULT")[((trial - 1) %% 3) + 1]
    target_loc  <- ((trial - 1) %% N_LOC) + 1
    cue_loc     <- sample(seq_len(N_LOC), 1)

    # Experiment <-> cue_size mapping mirrors load_data(): Exp1 is always
    # MEDIUM; Exp2 is SMALL or LARGE. Alternate experiment by trial parity.
    if (trial %% 2 == 0) {
      experiment <- "exp_1"
      cue_size   <- "MEDIUM"
    } else {
      experiment <- "exp_2"
      cue_size   <- if ((trial %% 4) == 1) "SMALL" else "LARGE"
    }

    S          <- make_S(target_loc, difficulty)
    is_repeat  <- (target_loc == prev_target)
    cue_at_prev <- (cue_loc == prev_target)

    # Response: target wins most of the time; a few error trials for realism.
    R <- if (trial %% 7 == 0) sample(setdiff(seq_len(N_LOC), target_loc), 1) else target_loc

    # RT in seconds, within the saccade cutoffs (0.23-1.0); faster when cued.
    base_rt <- runif(1, 0.30, 0.92)
    rt      <- round(if (cue_loc == target_loc) base_rt * 0.85 else base_rt, 4)

    block          <- ((trial - 1) %/% (N_TRIALS / N_BLOCKS)) + 1
    trial_in_block <- ((trial - 1) %% (N_TRIALS / N_BLOCKS)) + 1

    rows[[row_idx]] <- data.frame(
      experiment           = experiment,
      subjects             = sub,
      block                = block,
      trial_in_block       = trial_in_block,
      trials               = trial,
      rt                   = rt,
      R                    = R,
      S                    = S,
      search_difficulty    = difficulty,
      target_location      = target_loc,
      cue_location         = cue_loc,
      cue_size             = cue_size,
      is_target_repeated   = is_repeat,
      is_cue_at_prev_target = cue_at_prev,
      prev_target_location = prev_target,
      stringsAsFactors     = FALSE
    )
    row_idx <- row_idx + 1L

    prev_target <- target_loc
  }
}

df <- do.call(rbind, rows)

out_path <- "__tests__/fixtures/sample_data.csv"
write.csv(df, out_path, row.names = FALSE)
message(sprintf("Written %d rows (%d cols) to %s", nrow(df), ncol(df), out_path))
