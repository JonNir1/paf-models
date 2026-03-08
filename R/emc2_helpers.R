#' Appends a column "DistractorAtLoc" to the input `df`
#' DistractorAtLoc is an ordinal factor column with levels "T"<"D"<"E"
#' These values represent the stimulus presented at a specific location (stored in
#' column `df$lR`) based on the set of presented stimuly (stored in `df$S`)
DistractorAtLoc <- function(df) {
  clean_S <- gsub(",", "", as.character(df$S))
  loc_idx <- as.numeric(df$lR)
  res <- substr(clean_S, loc_idx, loc_idx)  # extract the character at location `loc_idx`
  res <- factor(res, levels = c("T", "D", "E"))
  return(res)
}


#' Append a column "CueAtLoc" to the input `df`
#' CueAtLoc is an ordinal factor column with levels "NONE"<"SMALL"<"LARGE"
#' The value is extracted for each stimulus-location (stored in column `df$lR`):
#' it checks if the location was cued (stored in `df#cue_location`), and returns
#' "NONE" if it wasn't, or the size of the cue (stored in `df#cue_size`) otherwie
CueAtLoc <- function(df) {
  cue_size <- toupper(as.character(df$cue_size))
  res <- ifelse(
    df$lR == df$cue_location,
    cue_size,
    "NONE"
  )
  res <- factor(res, levels=c("NONE", "SMALL", "MEDIUM", "LARGE"))
  return(res)
}



#' Appends a column "SearchDifficulty" to the input `df`
#' SearchDifficulty is an ordinal factor column with levels "EASY"<"MIXED"<"DIFFICULT"
#' The value is determined based on the `df` column `df$S`, which should be a
#' factor-column in the input data
SearchDifficulty <- function(df) {
  
  # Helper function to process a single string
  classify_string <- function(s) {
    elements <- trimws(unlist(strsplit(s, ",")))
    counts <- table(factor(elements, levels = c("T", "D", "E")))
    n_T <- counts["T"]
    n_D <- counts["D"]
    n_E <- counts["E"]
    
    # 1. Check for exactly one Target
    if (n_T != 1) {
      stop(paste("Invalid number of Targets (T) in string:", s))
    }
    # 2. Logic for Difficulty categorization
    if (n_E == 3) {
      return("EASY")
    } else if (n_D == 3) {
      return("DIFFICULT")
    } else if (n_D == 1 && n_E == 2) {
      return("MIXED")
    } else if (n_D == 2 && n_E == 1) {
      stop(paste("Unsupported distractor combination (2D, 1E) in string:", s))
    } else {
      stop(paste("String does not match any difficulty criteria:", s))
    }
  }
  
  # Apply the helper to every row
  s_vector <- as.character(df$S)
  results <- vapply(s_vector, classify_string, character(1), USE.NAMES = FALSE)
  results <- factor(
    results, levels = c("EASY", "MIXED", "DIFFICULT")
  )
  return(results)
}

