#' =============================================================================
#' Job plans: validate, lay out, estimate, persist, approve, launch.
#'
#' A plan is the unit of approval. `plan_create()` validates a job spec, prices
#' it, writes .paf-aws/plans/<id>.json (id = short hash of the canonical plan)
#' and returns the human approval block. `plan_launch()` re-validates, refuses
#' expired or tampered plans and submits the jobs to AWS Batch.
#'
#' Source chain: plan.R -> ledger.R -> aws_api.R -> cloud_config.R
#' =============================================================================

source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))
source_root("R/cloud/helpers/ledger.R")

PLAN_ID_REGEX <- "^[a-f0-9]{10}$"
PLAN_TIME_FORMAT <- "%Y-%m-%dT%H:%M:%SZ"
MODEL_SCRIPT_FLAGS <- c("--model-script", "--fit-model-script")


repo_root <- function() {
  root <- Sys.getenv("PAF_REPO_ROOT", unset = "")
  if (nzchar(root)) root else getwd()
}


#' Run git in the repo root; the mock seam for validation. Returns status + lines.
git_call <- function(args) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(repo_root()), args), stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  list(status = if (is.null(status)) 0L else status, out = as.character(out))
}


or_default <- function(x, default) if (is.null(x) || length(x) == 0L) default else x


# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

#' Stop unless every token is non-empty, matches [A-Za-z0-9._/=-] and has no `..`.
validate_arg_tokens <- function(tokens) {
  ok <- grepl(CLOUD_ARG_TOKEN_REGEX, tokens) & !grepl("..", tokens, fixed = TRUE)
  if (!all(ok)) {
    stop(sprintf("Invalid argument token(s) (allowed: letters, digits, . _ / = -; no '..'): %s",
                 paste(sprintf("'%s'", tokens[!ok]), collapse = ", ")), call. = FALSE)
  }
  invisible(tokens)
}


#' Full commit SHA of `ref`; stops if the ref is not a commit.
resolve_git_sha <- function(ref) {
  if (!grepl("^[A-Za-z0-9._/-]+$", ref)) stop(sprintf("Invalid git ref: '%s'", ref), call. = FALSE)
  res <- git_call(c("rev-parse", "--verify", "--quiet", paste0(ref, "^{commit}")))
  if (res$status != 0L || length(res$out) != 1L || !grepl("^[0-9a-f]{40}$", res$out)) {
    stop(sprintf("Git ref '%s' does not resolve to a commit", ref), call. = FALSE)
  }
  res$out
}


#' Stop unless `sha` is reachable from an origin branch (the container clones it).
validate_sha_on_origin <- function(sha) {
  remote <- git_call(c("branch", "-r", "--contains", sha))
  if (remote$status == 0L && any(grepl("^\\s*origin/", remote$out))) return(invisible(TRUE))
  tips <- git_call(c("ls-remote", "origin"))
  if (tips$status == 0L && any(startsWith(tips$out, sha))) return(invisible(TRUE))
  stop(sprintf("Commit %s is not on origin. Push the branch yourself first (the container clones this exact commit).",
               substr(sha, 1L, 12L)), call. = FALSE)
}


#' Stop unless every `--model-script`/`--fit-model-script` path exists on `sha`.
validate_model_scripts <- function(args, sha) {
  idx <- which(args %in% MODEL_SCRIPT_FLAGS)
  for (i in idx) {
    if (i == length(args)) stop(sprintf("%s needs a path", args[[i]]), call. = FALSE)
    path <- args[[i + 1L]]
    if (git_call(c("cat-file", "-e", sprintf("%s:%s", sha, path)))$status != 0L) {
      stop(sprintf("Model script '%s' does not exist at commit %s", path, substr(sha, 1L, 12L)), call. = FALSE)
    }
  }
  invisible(TRUE)
}


#' Validate every job of a plan (kind, tokens, env, model scripts, origin).
validate_jobs <- function(jobs, sha) {
  for (job in jobs) {
    if (!job$kind %in% CLOUD_ALLOWED_KINDS) {
      stop(sprintf("Unknown kind '%s' (allowed: %s)", job$kind, paste(CLOUD_ALLOWED_KINDS, collapse = ", ")), call. = FALSE)
    }
    validate_arg_tokens(as.character(unlist(job$args)))
    env <- unlist(job$env)
    if (length(env) > 0L) {
      if (!all(names(env) %in% CLOUD_OPTIONAL_ENV)) {
        stop(sprintf("Env var(s) not allowed: %s", paste(setdiff(names(env), CLOUD_OPTIONAL_ENV), collapse = ", ")), call. = FALSE)
      }
      validate_arg_tokens(unname(env))
    }
    validate_model_scripts(as.character(unlist(job$args)), sha)
  }
  validate_sha_on_origin(sha)
  invisible(TRUE)
}


# -----------------------------------------------------------------------------
# CLI parsing and job construction
# -----------------------------------------------------------------------------

#' Split `<kind> <args...> [+ <kind> <args...>]... [--ref R] [--market M] [--env N=V]...`
#'
#' `+` is not an allowed token character, so it can never be mistaken for an argument.
parse_plan_args <- function(args) {
  opts <- list(ref = "HEAD", market = "spot", env = list())
  rest <- character(0)
  i <- 1L
  while (i <= length(args)) {
    if (args[[i]] %in% c("--ref", "--market", "--env")) {
      if (i == length(args)) stop(sprintf("%s needs a value", args[[i]]), call. = FALSE)
      value <- args[[i + 1L]]
      if (args[[i]] == "--ref") opts$ref <- value
      if (args[[i]] == "--market") opts$market <- value
      if (args[[i]] == "--env") {
        kv <- strsplit(value, "=", fixed = TRUE)[[1]]
        if (length(kv) != 2L) stop("--env expects NAME=VALUE", call. = FALSE)
        opts$env[[kv[[1]]]] <- kv[[2]]
      }
      i <- i + 2L
    } else {
      rest <- c(rest, args[[i]])
      i <- i + 1L
    }
  }
  if (!opts$market %in% c("spot", "on-demand")) stop("--market must be 'spot' or 'on-demand'", call. = FALSE)
  if (length(rest) == 0L) stop("plan needs a kind, e.g. plan fit --model-script R/fit/m.R", call. = FALSE)
  groups <- split(rest, cumsum(rest == "+"))
  specs <- lapply(groups, function(g) g[g != "+"])
  if (any(lengths(specs) == 0L)) stop("empty job around '+'", call. = FALSE)
  c(opts, list(specs = unname(specs)))
}


#' Job records for specs (character vectors: kind first), with per-kind resources.
make_jobs <- function(specs, env = list()) {
  lapply(specs, function(spec) {
    row <- CLOUD_KINDS[CLOUD_KINDS$kind == spec[[1]], ]
    if (nrow(row) != 1L) stop(sprintf("Unknown kind '%s' (allowed: %s)", spec[[1]], paste(CLOUD_ALLOWED_KINDS, collapse = ", ")), call. = FALSE)
    list(kind = row$kind, args = spec[-1], env = env, vcpu = row$vcpu, memory_mib = row$memory_mib,
         instance_type = row$instance_type, timeout_hours = row$timeout_hours)
  })
}


# -----------------------------------------------------------------------------
# Layout, estimates, budget
# -----------------------------------------------------------------------------

market_cap <- function(market) if (market == "spot") MAX_CONCURRENT_VCPU else ONDEMAND_MAX_VCPU


#' Order-preserving first-fit packing of jobs into waves under a vCPU cap.
#'
#' Jobs of one wave run in parallel; waves run one after another.
#' @return List of integer index vectors (one per wave).
layout_jobs <- function(vcpus, cap) {
  if (any(vcpus > cap)) stop(sprintf("A job needs %d vCPU, above the cap of %d", max(vcpus), cap), call. = FALSE)
  waves <- list()
  used <- 0L
  for (i in seq_along(vcpus)) {
    if (length(waves) == 0L || used + vcpus[[i]] > cap) {
      waves[[length(waves) + 1L]] <- integer(0)
      used <- 0L
    }
    waves[[length(waves)]] <- c(waves[[length(waves)]], i)
    used <- used + vcpus[[i]]
  }
  waves
}


#' Wall time (h) and compute cost (USD) of a layout.
#'
#' @param jobs  data.frame: wall_hours (NA = unknown), timeout_hours, price_hr.
#' @param waves Layout from layout_jobs().
#' @return est_* are NA when any job's wall time is unknown; max_* use the timeouts.
estimate_cost <- function(jobs, waves) {
  wave_max <- function(x) vapply(waves, function(w) max(x[w]), numeric(1))
  list(est_wall_hours = sum(wave_max(jobs$wall_hours)),
       est_cost_usd   = sum(jobs$wall_hours * jobs$price_hr),
       max_wall_hours = sum(wave_max(jobs$timeout_hours)),
       max_cost_usd   = sum(jobs$timeout_hours * jobs$price_hr))
}


#' Expected wall hours of a kind: configured, else ledger median, else NA.
wall_hours_for <- function(kind, records = ledger_read()) {
  configured <- CLOUD_KINDS$wall_hours[CLOUD_KINDS$kind == kind]
  if (!is.na(configured)) return(configured)
  ledger_median_hours(kind, records)
}


price_per_hour <- function(instance_type, market) {
  if (market == "spot") aws_spot_price(instance_type) else ONDEMAND_PRICE_USD_HR[[instance_type]]
}


#' Month-to-date account spend (USD), cached COST_CACHE_HOURS (each CE call costs $0.01).
#' @return list(amount, fetched_at (POSIXct), cached)
month_to_date_spend <- function(now = Sys.time(), cache_dir = CLOUD_CACHE_DIR) {
  cache_path <- file.path(cache_dir, "cost_mtd.json")
  month <- format(now, "%Y-%m", tz = "UTC")
  if (file.exists(cache_path)) {
    cached <- tryCatch(jsonlite::fromJSON(cache_path), error = function(e) NULL)
    fetched <- if (!is.null(cached)) as.POSIXct(cached$fetched_at, format = PLAN_TIME_FORMAT, tz = "UTC")
    if (!is.null(cached) && identical(cached$month, month) &&
        difftime(now, fetched, units = "hours") < COST_CACHE_HOURS) {
      return(list(amount = as.numeric(cached$amount), fetched_at = fetched, cached = TRUE))
    }
  }
  today <- as.Date(format(now, "%Y-%m-%d", tz = "UTC"))
  amount <- aws_cost_mtd(as.Date(format(now, "%Y-%m-01", tz = "UTC")), today + 1L)
  dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
  writeLines(jsonlite::toJSON(list(month = month, amount = amount, fetched_at = format(now, PLAN_TIME_FORMAT, tz = "UTC")),
                              auto_unbox = TRUE, digits = NA), cache_path)
  list(amount = amount, fetched_at = now, cached = FALSE)
}


#' Budget verdict: the basis is the estimate, or the worst case when unknown.
budget_check <- function(mtd_usd, est_cost_usd, max_cost_usd, budget = MONTHLY_BUDGET_USD) {
  basis <- if (is.na(est_cost_usd)) max_cost_usd else est_cost_usd
  list(mtd_usd = mtd_usd, budget_usd = budget, basis = if (is.na(est_cost_usd)) "worst case" else "estimate",
       projected_usd = mtd_usd + basis, over = mtd_usd + basis > budget)
}


#' Price, size and budget-check a list of jobs; shared by plan and launch.
#' @return list(jobs_df, waves, estimate, budget, mtd, prices)
price_plan <- function(jobs, market, now = Sys.time()) {
  waves <- layout_jobs(vapply(jobs, function(j) as.integer(j$vcpu), integer(1)), market_cap(market))
  types <- unique(vapply(jobs, function(j) j$instance_type, character(1)))
  prices <- vapply(types, price_per_hour, numeric(1), market = market)
  records <- ledger_read()
  df <- data.frame(
    wall_hours    = vapply(jobs, function(j) wall_hours_for(j$kind, records), numeric(1)),
    timeout_hours = vapply(jobs, function(j) as.numeric(j$timeout_hours), numeric(1)),
    price_hr      = unname(prices[vapply(jobs, function(j) j$instance_type, character(1))])
  )
  est <- estimate_cost(df, waves)
  mtd <- month_to_date_spend(now)
  list(df = df, waves = waves, estimate = est, mtd = mtd, prices = as.list(prices),
       budget = budget_check(mtd$amount, est$est_cost_usd, est$max_cost_usd))
}


# -----------------------------------------------------------------------------
# Plan identity and persistence
# -----------------------------------------------------------------------------

#' Normalised, order-stable view of everything the approval covers (no clock, no prices).
plan_canonical <- function(plan) {
  named_chr <- function(x) {
    x <- unlist(x)
    if (length(x) == 0L) structure(list(), names = character(0)) else as.list(x[order(names(x))])
  }
  list(v = 1L, git_sha = plan$git_sha, market = plan$market,
       jobs = lapply(plan$jobs, function(j) {
         list(kind = j$kind, args = as.list(as.character(unlist(j$args))), env = named_chr(j$env),
              vcpu = as.integer(j$vcpu), memory_mib = as.integer(j$memory_mib), instance_type = j$instance_type,
              timeout_hours = as.numeric(j$timeout_hours), wave = as.integer(j$wave))
       }))
}


#' First 10 hex chars of the md5 of the canonical plan JSON.
plan_id <- function(plan) {
  tmp <- tempfile("plan_")
  on.exit(unlink(tmp), add = TRUE)
  writeLines(jsonlite::toJSON(plan_canonical(plan), auto_unbox = TRUE, digits = NA), tmp)
  substr(unname(tools::md5sum(tmp)), 1L, 10L)
}


plan_path <- function(id) file.path(CLOUD_PLANS_DIR, paste0(id, ".json"))


#' Load a plan; refuses a malformed id, a missing file, a tampered plan or an expired one.
plan_load <- function(id, now = Sys.time()) {
  if (!grepl(PLAN_ID_REGEX, id)) stop(sprintf("Invalid plan id: '%s'", id), call. = FALSE)
  if (!file.exists(plan_path(id))) stop(sprintf("No plan %s (run plan first)", id), call. = FALSE)
  plan <- jsonlite::fromJSON(plan_path(id), simplifyVector = FALSE)
  if (!identical(plan$id, id) || !identical(plan_id(plan), id)) {
    stop(sprintf("Plan %s was modified after it was created; refusing. Create a new plan.", id), call. = FALSE)
  }
  expires <- as.POSIXct(plan$expires_at, format = PLAN_TIME_FORMAT, tz = "UTC")
  if (is.na(expires) || now > expires) stop(sprintf("Plan %s expired at %s; create a new plan.", id, plan$expires_at), call. = FALSE)
  plan
}


# -----------------------------------------------------------------------------
# Approval block
# -----------------------------------------------------------------------------

fmt_hours <- function(h) if (is.na(h)) "unknown" else sprintf("%.2f h", h)
fmt_usd <- function(x) if (is.na(x)) "unknown" else sprintf("$%.2f", x)


#' Human approval block for a plan (character vector of lines).
format_plan <- function(plan) {
  est <- plan$estimate
  bud <- plan$budget
  jobs <- vapply(seq_along(plan$jobs), function(i) {
    j <- plan$jobs[[i]]
    sprintf("  %d. %-8s %s  [%d vCPU, %d MiB, %s, wave %d, timeout %s h]", i, j$kind,
            paste(unlist(j$args), collapse = " "), j$vcpu, j$memory_mib, j$instance_type, j$wave, format(j$timeout_hours))
  }, character(1))
  n_waves <- max(vapply(plan$jobs, function(j) j$wave, numeric(1)))
  layout <- if (n_waves == 1L && length(plan$jobs) > 1L) sprintf("parallel (%d jobs at once)", length(plan$jobs))
            else if (n_waves == 1L) "single job"
            else sprintf("serial in %d waves (vCPU cap %d)", n_waves, market_cap(plan$market))
  c(sprintf("=== PAF AWS plan %s ===", plan$id),
    sprintf("Commit:      %s @ %s", plan$git_ref, substr(plan$git_sha, 1L, 12L)),
    sprintf("Market:      %s (queue %s)", plan$market, plan$queue),
    sprintf("Jobs (%d):", length(plan$jobs)), jobs,
    sprintf("Layout:      %s; %d instance(s)", layout, length(plan$jobs)),
    sprintf("Price:       %s", paste(sprintf("%s $%.3f/h", names(plan$prices), unlist(plan$prices)), collapse = ", ")),
    sprintf("Est. wall:   %s (worst case %s)", fmt_hours(or_default(est$est_wall_hours, NA_real_)), fmt_hours(est$max_wall_hours)),
    sprintf("Est. cost:   %s (worst case %s), compute only", fmt_usd(or_default(est$est_cost_usd, NA_real_)), fmt_usd(est$max_cost_usd)),
    sprintf("Month-to-date: %s of %s budget; projected %s on %s -> %s", fmt_usd(bud$mtd_usd), fmt_usd(bud$budget_usd),
            fmt_usd(bud$projected_usd), bud$basis, if (isTRUE(bud$over)) "OVER BUDGET (launch refused)" else "within budget"),
    "Teardown:    Batch stops each job at its timeout; instances are released when the job ends; terminate any time with the terminate subcommand.",
    sprintf("Expires:     %s (%d min)", plan$expires_at, PLAN_TTL_MINUTES),
    sprintf("Launch:      Rscript R/cloud/paf_aws.R launch %s", plan$id))
}


# -----------------------------------------------------------------------------
# Plan creation
# -----------------------------------------------------------------------------

#' Validate, price and persist a plan.
#' @param opts Result of parse_plan_args().
#' @return The plan (list), invisibly after logging `planned` to the ledger.
plan_create <- function(opts, now = Sys.time()) {
  aws_assert_role()
  sha <- resolve_git_sha(opts$ref)
  jobs <- make_jobs(opts$specs, opts$env)
  validate_jobs(jobs, sha)
  priced <- price_plan(jobs, opts$market, now)
  for (w in seq_along(priced$waves)) for (i in priced$waves[[w]]) jobs[[i]]$wave <- w
  plan <- list(git_ref = opts$ref, git_sha = sha, market = opts$market,
               queue = if (opts$market == "spot") BATCH_QUEUE_SPOT else BATCH_QUEUE_ONDEMAND,
               jobs = jobs, prices = priced$prices,
               estimate = priced$estimate, budget = priced$budget,
               created_at = format(now, PLAN_TIME_FORMAT, tz = "UTC"),
               expires_at = format(now + PLAN_TTL_MINUTES * 60, PLAN_TIME_FORMAT, tz = "UTC"))
  plan$id <- plan_id(plan)
  dir.create(CLOUD_PLANS_DIR, recursive = TRUE, showWarnings = FALSE)
  writeLines(jsonlite::toJSON(plan, auto_unbox = TRUE, pretty = TRUE, digits = NA, na = "null"), plan_path(plan$id))
  ledger_append("planned", plan$id, list(kinds = vapply(jobs, function(j) j$kind, character(1)),
                                         git_sha = sha, market = opts$market,
                                         est_cost_usd = priced$estimate$est_cost_usd,
                                         max_cost_usd = priced$estimate$max_cost_usd))
  plan
}


# -----------------------------------------------------------------------------
# Launch
# -----------------------------------------------------------------------------

#' Container environment of one job: wrapper-controlled variables + allowed optional ones.
job_env <- function(plan, i) {
  job <- plan$jobs[[i]]
  c(list(PAF_GIT_SHA = plan$git_sha, PAF_KIND = job$kind, PAF_ARGS = paste(unlist(job$args), collapse = " "),
         PAF_RUN_ID = sprintf("%s-%d", plan$id, i), BUCKET = CLOUD_BUCKET_ROOT),
    as.list(unlist(job$env)))
}


ACTIVE_JOB_STATES <- c("SUBMITTED", "PENDING", "RUNNABLE", "STARTING", "RUNNING")


#' vCPUs currently held by active jobs, per queue.
active_vcpus <- function() {
  one_queue <- function(queue) {
    ids <- unlist(lapply(ACTIVE_JOB_STATES, function(s) aws_list_jobs(queue, s)))
    if (length(ids) == 0L) return(0L)
    sum(vapply(aws_describe_jobs(ids), function(j) {
      req <- Filter(function(r) identical(r$type, "VCPU"), or_default(j$container$resourceRequirements, list()))
      if (length(req) > 0L) as.integer(req[[1]]$value) else as.integer(or_default(j$container$vcpus, 0L))
    }, integer(1)))
  }
  c(spot = one_queue(BATCH_QUEUE_SPOT), ondemand = one_queue(BATCH_QUEUE_ONDEMAND))
}


#' Re-validate and submit a plan wave by wave (later waves depend on the previous one).
#' @return Character vector of job ids, in plan order.
plan_launch <- function(id, now = Sys.time()) {
  aws_assert_role()
  plan <- plan_load(id, now)
  launched <- Filter(function(r) identical(r$event, "launched") && identical(r$plan_id, id) && r$ts >= plan$created_at,
                     ledger_read())
  if (length(launched) > 0L) stop(sprintf("Plan %s was already launched; create a new plan to run again.", id), call. = FALSE)

  validate_jobs(plan$jobs, plan$git_sha)
  priced <- price_plan(plan$jobs, plan$market, now)
  if (priced$budget$over) {
    stop(sprintf("Over budget: month-to-date %s + %s (%s) exceeds %s.", fmt_usd(priced$budget$mtd_usd),
                 fmt_usd(priced$budget$projected_usd - priced$budget$mtd_usd), priced$budget$basis,
                 fmt_usd(priced$budget$budget_usd)), call. = FALSE)
  }
  peak <- max(vapply(priced$waves, function(w) sum(vapply(plan$jobs[w], function(j) as.integer(j$vcpu), integer(1))), numeric(1)))
  active <- active_vcpus()
  if (sum(active) + peak > MAX_CONCURRENT_VCPU || (plan$market == "on-demand" && active[["ondemand"]] + peak > ONDEMAND_MAX_VCPU)) {
    stop(sprintf("vCPU cap: %d active (spot %d, on-demand %d) + %d requested exceeds the limit. Wait or terminate jobs.",
                 sum(active), active[["spot"]], active[["ondemand"]], peak), call. = FALSE)
  }

  ids <- character(0)
  tryCatch({
    for (w in seq_along(priced$waves)) {
      previous <- if (w > 1L) ids[priced$waves[[w - 1L]]] else character(0)
      wave_ids <- character(0)
      for (i in priced$waves[[w]]) {
        job <- plan$jobs[[i]]
        ids[[i]] <- aws_submit_job(
          job_name = sprintf("paf-%s-%s-%d", job$kind, id, i), queue = plan$queue, env = job_env(plan, i),
          resources = list(vcpu = job$vcpu, memory_mib = job$memory_mib),
          tags = c(Project = "paf", Owner = "agent", PlanId = id, Kind = job$kind),
          timeout_hours = job$timeout_hours, depends_on = previous)
      }
    }
  }, error = function(e) {
    submitted <- ids[!is.na(ids) & nzchar(ids)]
    for (j in submitted) try(aws_terminate_job(j, "submit of plan failed part-way"), silent = TRUE)
    stop(sprintf("Launch failed (%d job(s) already submitted were terminated): %s", length(submitted), conditionMessage(e)), call. = FALSE)
  })
  ledger_append("launched", id, list(job_ids = ids, kinds = vapply(plan$jobs, function(j) j$kind, character(1)),
                                     market = plan$market, git_sha = plan$git_sha,
                                     est_cost_usd = priced$estimate$est_cost_usd, max_cost_usd = priced$estimate$max_cost_usd))
  ids
}
