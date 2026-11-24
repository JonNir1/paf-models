# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bayesian hierarchical cognitive modeling of the **PAF (Priority Accumulation Framework)** theory of visual attention, fit to saccade-latency data from two visual-search experiments. The full stack is **R + `EMC2`**: `R/helpers/data.R` ingests and reshapes the raw experimental CSVs, and a family of hierarchical LBA (Linear Ballistic Accumulator) models is fit and compared. (A legacy Python data pipeline was retired; see **Archived code** below.)

## Run from the repo root

Every R `source()` assumes the **repo root** as the working directory (e.g. `source("R/config.R")` appears inside scripts that themselves live under `R/`). Do not `cd` into a subdirectory before running anything.

## Common commands

There is **no linter or build system**. A `testthat` test suite lives in `__tests__/`. Verifying a change: run the relevant script AND the appropriate test level below.

R (modeling pipeline; from a fresh R session at repo root):
```
# Fit ONE model to convergence (unified entry; handles fresh OR pre-fitted models).
# Local/interactive: source fitting.R + your model script, then:
#   fit_to_convergence(build_model(data, N_CHAINS), convergence_criteria=..., save_path=...)
Rscript R/fit/fit_cloud.R --model-script R/fit/mymodel.R   # build fresh + fit to convergence
Rscript R/fit/fit_cloud.R --resume 260618_mymodel.rds      # resume a saved fit (called by scripts/run_fit.sh)
source("R/eval/convergence.R")                     # convergence table + verdict across discovered models
source("R/eval/goodness_of_fit.R")                 # GoF/model comparison (DIC/BPIC/LOO/WAIC)
source("R/eval/examine_model.R")                   # inspect a single fitted model
```

R (tests; requires `testthat` - `install.packages("testthat")`):
```
Rscript __tests__/run_tests.R                    # level 1: unit tests (seconds, no EMC2)
TEST_LEVEL=2 Rscript __tests__/run_tests.R       # level 2: + real-EMC2 tests, no MCMC (minutes)
TEST_LEVEL=3 Rscript __tests__/run_tests.R       # level 3: + fit smoke tests (CI only, ~1 h)
```

**Tiered testing strategy.** The suite is tiered by cost and intent; a higher TEST_LEVEL always runs the lower tiers too.

| Tier | Dir | Scope | Cost | When |
|---|---|---|---|---|
| L1 | `__tests__/helpers/` | Unit tests with no EMC2 installed. EMC2 is reached only through the `emc_*` wrappers in `R/helpers/emc2_api.R`, which the tests mock (`local_mocks()` in `__tests__/fixtures/common.R`). Covers the pure helpers, `load_data()` end to end on synthetic raw CSVs, config invariants, naming/I/O, and the fit/PPC/recovery orchestration (`fit_to_convergence` loop, `run_ppc_simulation`, `run_recovery_fit`, `build_lba_model` wiring). | seconds | Every push/PR (CI auto) + manual dispatch. |
| L2 | `__tests__/models/` | Real EMC2, no MCMC. `test_recovery_build.R` builds the synthetic `test_model` **once** (dominated by `EMC2::design()`) and checks the build + simulate step. `test_fitted_fixture.R` runs on the committed tiny fit `__tests__/fixtures/test_model_fitted.rds` (an EMC2 3.5.0 fit) plus the legacy 3.4.1 fit `test_model_fitted_3.4.1.rds`: EMC2 object shapes (`check()`, `get_pars()`, prior), per-trial log-lik vs EMC2's own likelihood (on both fits, proving a 3.4.1 fit needs no migration), GoF DIC/BPIC identities, the LOO table and comparison end to end, `recovery_emc2_rows`, PPC simulation. | minutes | Nightly + manual dispatch (CI). |
| L3 | `__tests__/fit/` | End-to-end smoke tests with tiny MCMC (n_chains=2), driven by the synthetic model. One file (`test_fit_smoke.R`): **Smoke A/B** = `fit_to_convergence` (fresh + resume), **Smoke C** = recovery (incl. the rebuild on simulated data). | ~1 h | Weekly (Sun 04:00 UTC) + manual dispatch (CI). |

CI (GitHub Actions):
- L1 runs automatically on every push and on PRs to `main`, and on manual dispatch: Actions tab → "Tests" → "Run workflow" (`.github/workflows/test.yml`).
- L2 is **not** per-push (intrinsically slow: `EMC2::design()` is ~minutes per model). It runs nightly (03:00 UTC) and on manual dispatch: Actions tab → "Build Tests" → "Run workflow" (`.github/workflows/build.yml`).
- L3 runs weekly (Sundays 04:00 UTC, to catch upstream EMC2 changes; EMC2 is not pinned) and on manual dispatch: Actions tab → "Smoke Tests" → "Run workflow" (`.github/workflows/smoke.yml`).
- Scheduled workflows run only from the default branch, and GitHub disables them after 60 days without repo activity; re-enable with `gh workflow enable <file>.yml` or the "Enable workflow" button in the Actions tab.
- `use-public-rspm: true` serves pre-compiled Linux binaries; EMC2 installs in ~2 min instead of compiling from source.
- Package caches are keyed on `.github/r-deps-level1.txt` / `r-deps-level2.txt` and auto-invalidate when the dep list changes.

When adding a new pipeline, test its logic at L1 (mock the `emc_*` seam; call EMC2 only through those wrappers so L1 stays EMC2-free), its real EMC2 calls at L2 (on the fitted fixture where possible, no MCMC), and add an L3 smoke only if it needs fresh MCMC. If the fitted fixture's EMC2 major.minor no longer matches the installed EMC2, L2 skips with a hint: regenerate it with `__tests__/fixtures/generate_fitted_fixture.R` (~20-45 min locally).

## Agent tooling (local, project-authored)

The repo ships Claude Code tooling tuned to this PAF/EMC2 pipeline (tracked for reproducibility; vendored third-party skills under `.claude/skills/` are gitignored and reinstallable via `npx skills add`):
- **`.claude/agents/`** — three subagents: **Coder** (clean/reusable/efficient R, reuses `build_lba_model`/`fit_to_convergence`), **Tester** (adversarial tests + prunes the suite; testthat 3 via the `testing-r-packages` skill), **Reviewer** (read-only audit of code + tests). All are EMC2-fluent (docs: https://r-packages.io/packages/EMC2) and pipeline-aware (model spec → fit → convergence → recovery → GoF → PPC → OOD).
- **`/code-test-review-loop`** (`.claude/skills/code-test-review-loop/`) — orchestrates a looped Coder → Tester → Reviewer cycle with warm agents (continued via `SendMessage`), a persistent open-issues ledger, and an iteration cap; `iterations=1` for a single pass. The loop is sequential within an iteration (Coder + Tester both write the shared tree; Reviewer reads a stable snapshot).
- The agents ground in the working tree / `git diff`, not authorship memory, so they work mid-stream on already-written code (e.g. a Tester-first "brownfield" pass).

## Data loading (R-native pipeline)

The pipeline reads raw experiment CSVs directly in R:

1. `R/helpers/data.R` `load_data()` reads `data/exp{1,2}/Exp{1,2}_clean.csv`, applies all column transforms (renaming, distractor-string construction, RT conversion, boolean mapping, cue-size encoding), enforces ordered factors (`search_difficulty` ∈ {EASY < MIXED < DIFFICULT}, `cue_size` ∈ {NONE < SMALL < MEDIUM < LARGE}), and applies RT cutoffs -- returning the same 15-column tibble as before.

`data/` is **gitignored** (see `.gitignore:2`). A fresh clone has no data; the raw cleaned CSVs must be supplied locally.

The earlier Python data pipeline (`load_data.py`, `enum_types.py`, `playground.py`) and its `data/emc2_design_matrix.csv` intermediate were retired and removed from `main`; they live on the `archive/legacy-python` branch (see **Archived code** below).

## Architecture

- **`R/` layout**: split into three layers.
  - `R/config.R` — project-level: RNG (`seed = 42`, `L'Ecuyer-CMRG`), saccade RT cutoffs (0.23 to 1.0 s), the asymmetric convergence thresholds (`MAX_RHAT_MU`/`MIN_ESS_MU` + `MAX_RHAT_ALPHA`/`MIN_ESS_ALPHA`; used by BOTH the fit and eval layers), and output dir paths (`OUTPUTS_DIR`, `MODELS_DIR`, `EVAL_DIR`, `MODELS_FIT_DIR`, `MODELS_RECOVERY_DIR`). `CODE_DIR` and `FIT_CONFIG_FILE` resolve against `PAF_REPO_ROOT` (default: cwd); the data and output dirs stay cwd-relative. Sourced (directly or transitively) by every script.
  - `R/utils.R` — `source_root(rel)`, `parse_int_arg`, `parse_str_arg`, `check_valid_string`, `read_top_level`, `find_model_script` (locate a model script by its declared `MODEL_NAME`). Sourced as the FIRST line of every R file via `source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))`.
  - `R/fit/`: fitting code (`fit_cloud.R`, `fit_recovery_cloud.R`, `fit_ppc_cloud.R`, `fit_bf_cloud.R`) + `R/fit/fit_config.R` (the intercept priors `v`/`B`/`A`/`t0` only (effect priors belong to each model), `SIM_RT_WINDOW`, `N_CHAINS = 3`, fit-loop defaults `MAX_TRIES=20`/`STEP_SIZE=200`/`SAVE_EVERY=2`/`EXTENDED_FIT_SAMPLES=3000`, the `default_convergence_criteria()` builder, recovery params, and the `CONSTANTS = c(sv = log(1))` identifiability anchor). The asymmetric convergence thresholds live in `R/config.R` (shared with eval). Model definitions are NOT on `main` (the model1-5 family is archived on the `analysis1` branch); add a new model as a thin script defining `build_model()`/`MODEL_NAME` (see `__tests__/fixtures/test_model.R`).
  - `R/eval/` — evaluation code: `convergence.R` (convergence table + verdict), `goodness_of_fit.R` (GoF/DIC/BPIC/LOO/WAIC), `recovery.R` (parameter-recovery analysis), `ppc.R` (posterior predictive checks), `review_convergence_and_recovery.R` (convergence+recovery synthesis), `examine_model.R` (interactive) + `R/eval/eval_config.R` (incl. `discover_model_names()` and `model_colors()`).
  - `R/helpers/` — cross-cutting helpers used by both fit and eval: `logging.R`, `data.R`, `emc2_api.R` (the `emc_*` EMC2 seam and the shared `check_block_values()` parser).
  - `R/fit/helpers/` — fit-only helpers: `build_model.R`, `fitting.R`, `recovery.R`.
  - `R/eval/helpers/`: eval-only helpers: `convergence.R` (Rhat/ESS extraction + verdict), `recovery.R` (recovery-eval computations), `gof.R` (GoF computations), `ppc.R` (PPC computations), `bf.R` (marginal likelihoods / Bayes-factor table), `model_recovery.R` (model-selection + confusion matrix), `plot.R` (ggplot2 figures), `io.R` (`load_model`, `save_eval_table`, `eval_cache_fresh`, `latest_dated_file`).
  - **Duplicated filenames — driver vs. helper.** Several names appear in two places; the split is always *driver in the layer dir, computations in its `helpers/`*: `R/eval/convergence.R` is the runnable driver (builds the table + verdict, writes `convergence.{rds,csv}`) while `R/eval/helpers/convergence.R` holds the Rhat/ESS extraction it calls; likewise `R/eval/recovery.R` (driver) vs `R/eval/helpers/recovery.R` (computations). `recovery.R` also exists under `R/fit/helpers/` — that one is unrelated (fit-side: `extract_group_params`/`simulate_recovery_data`), not an eval file. When editing, confirm which layer you're in before assuming behavior.
  - Parallelism (`cores_for_chains`, `cores_per_chain`) is auto-detected at runtime by `get_core_args()` in `R/fit/helpers/fitting.R` — no manual core config is needed.
- **Output locations** (from `R/config.R`):
  - `MODELS_FIT_DIR      = "outputs/models/fit"`          — `.rds` files from the unified fit pipeline (`fit_cloud.R` / `fit_to_convergence`), named `YYMMDD_<MODEL_NAME>.rds`, + per-model logs `log_fit_<name>.txt`.
  - `MODELS_RECOVERY_DIR = "outputs/models/fit_recovery"` — `.rds` files from `fit_recovery_cloud.R`.
  - `MODELS_BF_DIR       = "outputs/models/fit_bf"`        - per-fit marginal-likelihood files + logs from `fit_bf_cloud.R` (`R/eval/eval_config.R`).
  - `EVAL_DIR            = "outputs/evaluation"`          — eval outputs (`convergence.{rds,csv}`, GoF tables, recovery analysis under `parameter_recovery/`, PPC under `ppc/`).
  - `LOG_FILE` is **not** in `config.R`; each fit derives its log via `model_log_path()` (e.g. `outputs/models/fit/log_fit_<name>.txt`).
- **Defining a model**: a model is a thin script defining `MODEL_NAME` and `build_model(data, n_chains)`, which delegates to `build_lba_model()` in `R/fit/helpers/build_model.R`. `build_lba_model()` owns all shared boilerplate (`design()`, `prior()`, `make_emc()`); each model passes its `v_formula`, `B_formula`, `sv_formula` (all required; `A_formula` defaults to `A ~ 1`), the prior of every effect it samples via `extra_mu`/`extra_sd` (`fit_config.R` holds only the `v`/`B`/`A`/`t0` intercepts; a sampled parameter without a prior is an error), and optionally `functions =` (the factor closures given to `design()`; default all of `LBA_FUNCTIONS`, pass only those the formulas use to cut `design()` time). Each model script must also declare `STRUCTURAL_UNIDENTIFIABLE_PATTERN`: a single regex for the parameters its design cannot identify (excluded from the "core" recovery statistics), or `NA_character_` if every parameter is identifiable. The recovery eval reads it via `model_unidentifiable_pattern()` (`R/eval/helpers/recovery.R`), which finds the script by its declared `MODEL_NAME` via `find_model_script()` (`R/utils.R`; any file name, but names must be unique among the `*.R` files directly in `MODEL_SCRIPT_DIR`, default `R/fit/`, pre-settable before sourcing the driver) and reads the declaration by parsing the script WITHOUT executing it: it must be a top-level assignment (`<-` or `=`) with a self-contained right-hand side (a literal or base-R expression); the pattern must also be non-empty, valid, and must not match every parameter. A missing or duplicated `MODEL_NAME`, missing declaration, non-character value, invalid regex, or a non-NA pattern matching none of the model's parameters is a fatal error (no default, not downgraded by `ALLOW_PARTIAL_RECOVERY`). `__tests__/fixtures/test_model.R` is a minimal template; the archived `model1`–`model5` (branch `analysis1`) are fuller examples.
  - **Per-model data subset**: a script may declare a top-level `MODEL_DATA_ARGS <- list(...)` of extra `load_data()` arguments (e.g. `list(difficulties = c("EASY", "DIFFICULT"))`), read WITHOUT executing the script by `model_data_args()` (`R/helpers/data.R`, same contract as `STRUCTURAL_UNIDENTIFIABLE_PATTERN`; absent = `list()`). Names must be formals of `load_data()` and may not be `data_dir`/`min_rt`/`max_rt`/`allow_target_repeats` (the runners take those from `R/config.R`); otherwise fatal. Every runner loads a model's data via `load_model_data(<script>)`: `fit_cloud.R` (`--model-script`), `fit_recovery_cloud.R` and `fit_ppc_cloud.R` (script found by the fit's model name via `find_model_script()`), and `R/eval/ppc.R` (per model, one load per distinct subset). A recovery refit model (`--fit-model-script`) must declare the same `MODEL_DATA_ARGS` as the generating model.
- **Unified fitting** — `fit_to_convergence(emc, convergence_criteria, max_tries, batch_size, save_every=NULL, post_save_hook=NULL, save_path=NULL, ...)` in `R/fit/helpers/fitting.R` is the single entry point (replaces the retired `fit_initial` + `fit_extend_*`):
  - Takes an EMC2 object (not a path). A **fresh** (unfitted) model is warmed up via `EMC2::fit()` (preburn→burn→adapt→initial sample batch); a **pre-fitted** model skips straight to the extension loop. Detection is by the sample-stage iteration count (`.sample_iters()`).
  - The loop adds `batch_size` sampling iters per try (via `run_emc(stage="sample")`) until `convergence_criteria` is met or `max_tries` is exhausted. Convergence = every gated group meets its Rhat/ESS thresholds AND the sample-stage count reaches `num_samples`.
  - `convergence_criteria` is a list: `num_samples` (sample-stage floor) + per-group `list(max_rhat=, min_ess=)` for any of `mu`/`Sigma2`/`alpha`/`correlation`. **Omitted groups are descriptive-only (not gated)** — `default_convergence_criteria()` gates `mu`+`alpha`. Generic check via `check_convergence()`.
  - `save_path`/`save_every` control checkpointing; `post_save_hook(rds_path, log_path)` runs after each save (cloud S3/GCS sync). Inputs are validated up front (`.validate_convergence_criteria()`, `.validate_fit_args()`): reachability (`existing + batch_size*max_tries >= num_samples`), `1 <= save_every <= max_tries`, etc.
  - `fit_cloud.R` is the thin single-model runner (build-fresh via `--model-script` OR `--resume <rds>`) that supplies the cloud hook; `scripts/run_fit.sh` wraps it on a VM.
- **Factor level orderings**: `R/helpers/data.R` is the single source of truth for the canonical level orderings, encoded through closure functions (`StimulusAtLoc`, `TargetAtLoc`, `CueAtLoc`, `PrevTargetAtLoc`, `SearchDifficulty`) that EMC2's `design()` calls. (The original Python `enum_types.py` definitions are preserved on the `archive/legacy-python` branch but are no longer authoritative.)
- **Latest-version lookup**: `R/eval/helpers/io.R` `load_model()` parses the `YYMMDD_` prefix and always returns the most recent `.rds` for a given model name. `latest_dated_file()` stops with "Ambiguous latest file" if several files share the latest date, rather than picking by directory order.
- **Eval driver knobs (all pre-settable before sourcing a driver)**: `MODEL_NAMES` (every eval driver uses it if set instead of `discover_model_names()`, and `check_model_names()` fails clearly if a name has no fit; this is how to run a driver on a model subset), `MODEL_EXCLUDE_PATTERN` (regex of names `discover_model_names()` drops; default `NA_character_` = none; an explicit `MODEL_NAMES` may still name an excluded model), and the output locations `BF_DIR` (Bayes-factor table + cache), `GOF_DIR` (DIC/BPIC table, default `EVAL_DIR`) and `LOO_DIR` (LOO tables + cache), so a separate comparison (e.g. a sensitivity-fit subset) writes elsewhere and never overwrites the main tables; the cache path, and hence the cache, follows. `convergence.R`, `recovery.R`, `ppc.R` and `model_recovery.R` write to fixed dirs (only the model subset is configurable). The PPC figures' default x variable is `ppc_x_var()`: the first `PPC_GROUP_VARS` entry other than `experiment` (`cue_size` by default). Model names in file-matching regexes always go through `regex_escape()`.
- **Eval caching**: `eval_cache_fresh(cache_path, input_paths, cache_key)` reuses a cached table only if it is newer than every input file (`newer_than_inputs()`, mtime) AND its stored `cache_key` matches. Keys include the model files used, the convergence/GoF thresholds, and the EMC2 (and, for LOO, `loo`) versions, so a model-set, threshold or EMC2-version change invalidates the cache.
- **EMC2 version stamping**: saved fits carry `attr(, "emc2_version")` (current) and `attr(, "emc2_version_history")` (ordered unique versions it was saved under), set by `stamp_emc2_version()` in `R/fit/helpers/fitting.R`; each CLI run also logs the EMC2 version. `EMC2::run_emc()` strips custom attributes, so `fit_to_convergence()` remembers the incoming history and restores it before every save.
- **CLI exit codes**: `fit_cloud.R`, `fit_recovery_cloud.R` and `fit_ppc_cloud.R` exit with status 1 on error. `--resume` validates the loaded object (`.validate_resume_model()`: must be an EMC2 object with sample-stage iterations) and errors if the file is missing. The recovery CLI finds the model script by its declared `MODEL_NAME` (the fit file's model name) via `find_model_script()`, so the script may have any file name but must live in `R/fit/` (checked up front, before anything is computed or written).

## Analysis workflow

The new analysis (new model family) is being set up; the step-by-step plan is a **skeleton** in `README.md` ("Analysis plan") pending the new model specs. Steps marked `X.9` are **stop-and-review checkpoints**: surface diagnostics and prompt a discussion (PI where noted) rather than auto-proceeding. Do not pre-decide outcomes at these checkpoints.

The **completed** `model1`–`model5` analysis (through step 4.9: convergence, recovery, GoF, PPC) is archived on branch `analysis1` (tag `analysis1-v1.0`); consult it for the prior 16-step plan and findings.

**Baseline tags**: `analysis1-v1.0` marks the archived model1-5 world; `unified-pipeline-v1.0` marks the earlier unified-pipeline `main` baseline (the first state with the unified pipeline CI-green across all tiers (L1 + L2 build/recovery + L3 smoke A/B/C/D) on real EMC2); **`v1.2`** marks the current `main` baseline, the clean-slate generic pipeline (no model definitions, generic eval knobs), CI-green on all tiers on 2026-11-24. Revert/branch from any of them with `git switch -c <name> <tag>`.

**Asymmetric convergence target** (production default, encoded in `default_convergence_criteria()` reading `R/config.R`):

| Block | Rhat | ESS bulk | Notes |
|---|---|---|---|
| `$mu` | < 1.05 | > 500 | Population params reported with CIs; tighter Rhat than EMC2 default. |
| `$alpha` | < 1.1 | > 400 | EMC2-default-aligned; subject-level params feed OOD simulation. |
| `$sigma2` | descriptive only | descriptive only | Omitted from `convergence_criteria` => not gated; report descriptively. |
| `$correlation` | descriptive only | descriptive only | Routinely non-convergent in hierarchical LBA; report as known limitation. |

`fit_to_convergence()` gates only the groups present in `convergence_criteria`, evaluated by `check_convergence()` in `R/fit/helpers/fitting.R`.

**No forced single winner**: GoF and OOD rankings are reported jointly. The analysis may legitimately conclude with co-winners or with different "best" models for different criteria.

## Important files

Project-level:
- `R/config.R` - RNG, RT cutoffs, paths (`OUTPUTS_DIR`, `MODELS_*_DIR`, `EVAL_DIR`, `DATA_DIR`)
- `R/utils.R` - `source_root()` plus `parse_int_arg`, `parse_str_arg`, `check_valid_string`, `read_top_level`, `find_model_script`
- `R/helpers/logging.R` - timestamped logging, error reporting, config serialisation
- `R/helpers/data.R` - **entry point `load_data()`** reads raw CSVs end-to-end; `filter_data()` for custom RT cutoffs on an already-loaded tibble; `.encode_factors()` (canonical factor encoding, shared with the test fixtures); EMC2 factor closures (`StimulusAtLoc`, `TargetAtLoc`, `CueAtLoc`, `PrevTargetAtLoc`, `SearchDifficulty`); sources `logging.R`
- `R/helpers/emc2_api.R` - thin `emc_*` wrappers (`emc_fit`, `emc_run`, `emc_check`, `emc_get_pars`, `emc_make_data`, `emc_design`, `emc_compare`, `emc_recovery`, `emc_bridge_sampling`, `emc_version`, ...), each a plain `EMC2::<fn>(...)`, plus `check_block_values()`, the single parser of `check()` blocks (Rhat/ESS) shared by the fit gate and the eval convergence table. The fit layer, recovery helpers, PPC runner and the eval convergence/GoF/recovery helpers call EMC2 only through these so L1 can mock them (the per-trial log-likelihood extraction in `R/eval/helpers/gof.R` still reaches into an unexported EMC2 function and is covered at L2)

Fitting (`R/fit/`):
- `R/fit/fit_config.R` - priors, `N_CHAINS`, fit-loop defaults, `default_convergence_criteria()`, recovery params, `CONSTANTS` (asymmetric convergence thresholds in `R/config.R`)
- `R/fit/fit_cloud.R` - unified single-model runner: build-fresh (`--model-script`) OR resume (`--resume <rds>`); supplies the S3/GCS cloud hook (called by `scripts/run_fit.sh`)
- `R/fit/fit_recovery_cloud.R` - cloud single-sim parameter recovery via `fit_to_convergence()` (called by `scripts/run_recovery.sh`)
- `R/fit/fit_ppc_cloud.R` - cloud posterior predictive simulation (called by `scripts/run_ppc.sh`)
- `R/fit/fit_bf_cloud.R` - cloud bridge-sampling MLL of one fit (called by `scripts/run_bf.sh`)
- `R/fit/helpers/build_model.R` - `build_lba_model()` factory; sources `fit_config.R` and `R/helpers/data.R`
- `R/fit/helpers/fitting.R` - `get_core_args`, `save_model`, `check_convergence`, **`fit_to_convergence`** (single fit entry point), `model_log_path`, validators; sources `build_model.R`.
- `R/fit/helpers/recovery.R` - `extract_group_params`, `extract_design`, `simulate_recovery_data`; sources `fitting.R`.
- New model definitions live alongside these as thin scripts; none are committed on `main` yet (see `__tests__/fixtures/test_model.R` for the template).

Evaluation (`R/eval/`):
- `R/eval/eval_config.R` - eval params, `RECOVERY_EVAL_DIR`, `discover_model_names()` (active set), `model_colors()`, GoF/PPC thresholds
- `R/eval/convergence.R` - convergence table + verdict over discovered models (writes `convergence.{rds,csv}`)
- `R/eval/goodness_of_fit.R` - GoF/model comparison (DIC/BPIC/LOO/WAIC)
- `R/eval/bayes_factors.R` - marginal likelihoods + log Bayes factors (bridge sampling)
- `R/eval/model_recovery.R` - model recovery confusion matrix (generating x selected)
- `R/eval/recovery.R` - load recovery fits, produce population table + subject scatter + z-score/contraction plots
- `R/eval/ppc.R` - posterior predictive checks (per-subject KS + theory contrasts)
- `R/eval/review_convergence_and_recovery.R` - convergence + recovery synthesis
- `R/eval/examine_model.R` - inspect a single fitted model
- `R/eval/helpers/convergence.R` - Rhat/ESS extraction, `create_convergence_table()`, `add_convergence_verdict()`
- `R/eval/helpers/recovery.R` - recovery-eval computations (prior-SD extraction, z-score/contraction, RMSE/r)
- `R/eval/helpers/gof.R` - goodness-of-fit computations (DIC/BPIC/LOO/WAIC)
- `R/eval/helpers/ppc.R` - PPC computations (per-subject KS, theory contrasts)
- `R/eval/helpers/plot.R` - ggplot2 figure builders + `save_ggplot_png()` (PNG export via ragg)
- `R/eval/helpers/io.R` - `latest_dated_file()` (errors on a same-date tie), `model_rds_pattern()` / `model_name_from_rds()` (the single `YYMMDD_<name>[_extended].rds` naming rule), `load_model()` (exact name, latest date), `save_eval_table()`, `newer_than_inputs()` + `eval_cache_fresh()` (cache freshness; shared eval I/O)

Other:
- `scripts/helpers.sh` - shared config defaults and cloud copy helpers (sourced by the scripts below)
- `scripts/vm_setup.sh` - one-time R + EMC2 install on a fresh Ubuntu VM
- `scripts/run_fit.sh` - build-fresh OR resume a fit on a VM via `fit_cloud.R`, sync results
- `scripts/run_recovery.sh` - download a fit, run `fit_recovery_cloud.R`, sync results
- `scripts/run_ppc.sh` - download a fit, run `fit_ppc_cloud.R`, sync results
- `scripts/run_bf.sh` - download a fit, run `fit_bf_cloud.R`, sync the MLL file to `results/bf/`
- `__tests__/run_tests.R` - test entry point; gated by `TEST_LEVEL` env var (1/2/3)
- `__tests__/fixtures/sample_data.csv` - committed synthetic fixture matching `load_data()`'s output contract (one row per trial, 15 columns, 120 rows); regenerate with `generate_fixture.R`
- `__tests__/fixtures/test_model.R` - minimal synthetic LBA model (`build_model()` + `MODEL_NAME`) exercised by L2/L3, with its effect priors declared as `TEST_MODEL_PRIOR_MU`/`TEST_MODEL_PRIOR_SD` (values the committed fitted fixtures were made with; do not change), plus `test_group_params()` (in-bounds group params from `PRIOR_MU` + `TEST_MODEL_PRIOR_MU`)
- `__tests__/fixtures/common.R` - shared test infrastructure for every tier: `local_mocks()` (rebinds sourced functions; `local_mocked_bindings()` needs a package, this repo has none), mock EMC2 objects and call recorders, `load_fixture_raw()`/`load_fixture_data()`, `SMOKE_STOP_CRITERIA`/`TRIVIAL_CC`, `load_fitted_fixture()`
- `__tests__/fixtures/test_model_fitted.rds` - committed tiny fit of the synthetic model (2 chains, 100 sample iters, an EMC2 3.5.0 fit; records its EMC2 version); regenerate with `generate_fitted_fixture.R`
- `__tests__/fixtures/test_model_fitted_3.4.1.rds` - the previous fixture, kept as a legacy 3.4.1 fit; `test_fitted_fixture.R` runs the log-likelihood checks on it to prove 3.4.1-made fits work under 3.5.0 unmigrated
- `__tests__/helpers/` - L1 unit tests (no EMC2)
- `__tests__/models/` - L2 real-EMC2 tests: `test_recovery_build.R` (one build) + `test_fitted_fixture.R` (on the fitted fixture)
- `__tests__/fit/test_fit_smoke.R` - L3 smoke tests on the synthetic model: Smoke A/B (`fit_to_convergence` fresh + resume), Smoke C (recovery). CI weekly + manual dispatch. Bounded `stop_criteria` (`max_gd=Inf`) makes all EMC2 phases exit after a fixed iteration count.
- `.github/workflows/test.yml` - CI: L1 unit tests (auto on push/PR to `main` + manual dispatch)
- `.github/workflows/build.yml` - CI: L2 build tests (nightly 03:00 UTC + manual dispatch)
- `.github/workflows/smoke.yml` - CI: L3 smoke tests (weekly + manual dispatch)
- `.github/r-deps-level1.txt` / `r-deps-level2.txt` - package lists used by CI cache keys

## Gotchas

- Running an R script with the wrong cwd silently fails on the first `source("R/config.R")`. Always start from the repo root.
- `fit_cloud.R` wraps the fit in `tryCatch`; treat the per-model log (`outputs/models/fit/log_fit_<name>.txt`) as authoritative for run status, not stdout. `fit_to_convergence()` validates its arguments up front (criteria shape, `save_every` bounds, reachability) so misconfigs fail in milliseconds, not hours in.
- `CONSTANTS = c(sv = log(1))` in `R/fit/fit_config.R` is an **identifiability anchor** for the LBA. Removing or changing it will silently make the model non-identifiable.
- Dependencies are not pinned in any manifest. R: `EMC2`, `dplyr`, `readr`, `tools`, `testthat`, `loo` (GoF LOO/WAIC; EMC2 3.5.0 has none). (The retired Python pipeline's deps are documented on the `archive/legacy-python` branch.)
- R environment on the local machine:
  - `R_HOME = C:\Program Files\R\R-4.5.2`
  - `R_LIBS_USER = C:\Users\nirjo\R_library\4.5`
  - The system library under `R_HOME` is not writable; install packages to `R_LIBS_USER`.
  - Do not add `.libPaths(file.path(Sys.getenv("USERPROFILE"), "R", "library"))` to test files (it was removed from all of them): it resolves to the wrong path on this machine (`C:\Users\nirjo\R\library` vs the actual `R_LIBS_USER`). Rely on `R_LIBS_USER`.
  - **L3 smoke C is flaky on Windows**: EMC2 starts PSOCK socket clusters inside its own parallel workers, which intermittently fails with "creation of server socket failed: port ... cannot be opened" (1 pass in 4 local runs on identical code). Linux CI forks instead of using sockets; treat a local smoke C socket error as this flake, not a regression.
  - **Running `Rscript` from the Bash tool: set `R_LIBS_USER` first.** Bare `Rscript` falls back to the Claude app's sandboxed R library (`AppData/Local/Packages/Claude_.../R/win-library/4.5`) which has an older `rlang` that conflicts when loading `readr`/`EMC2`. Prefixing with `R_LIBS_USER="C:/Users/nirjo/R_library/4.5"` puts the user library first and `readr`/`dplyr`/`EMC2` load cleanly (verified). The PATH `Rscript` is already the real `R-4.5.2`. Recipe: `R_LIBS_USER="C:/Users/nirjo/R_library/4.5" Rscript <script>`. **EMC2 version on this machine:** the pipeline is verified on EMC2 3.5.0 (CRAN, 2026-07-14). 3.5.0 is installed in the main library `C:\Users\nirjo\R_library\4.5` (promoted 2026-11-16; 3.4.1 is no longer installed locally). **eval/check/recovery analysis can run locally this way; heavy MCMC fitting still belongs on the cloud.** Note: `outputs/` and `data/` live in the main checkout, not the worktree — run eval from the main-repo cwd with `PAF_REPO_ROOT` pointed at the worktree to use edited code against real data.
- **EMC2 API / object structure reference**: https://www.rdocumentation.org/packages/EMC2/versions/3.3.0 (function docs for `check()`, `get_pars()`, `recovery()`, `make_data()`, `make_random_effects()`, etc.). The rdocumentation mirror is for 3.3.0; the pipeline is verified on **3.5.0** (3.4.1 also still works; see the install note above), so verify against the installed version if a signature or return shape differs. Empirically confirmed shapes (3.4.1, re-verified on 3.5.0): `check()` returns per-block `chk[[g]][[g]]` as a 2-row matrix (row 1 Rhat, row 2 ESS), with `chk$alpha` a per-subject list of such matrices; `get_pars(selection="mu")` returns an mcmc.list; `get_pars(selection="alpha", return_mcmc=TRUE)` is **parameter-keyed** (list of length n_pars, each `[samples x subjects]`); `prior$theta_mu_var` holds the population-mean prior covariance (`sqrt(diag(.))` = prior SDs); `recovery()` returns a per-parameter list with `$stats` (pearson/spearman/rmse/coverage) and `$quantiles`. 3.5.0 API changes: `recovery()` has NO `do_plot` argument (it always plots; `emc_recovery()` in `R/helpers/emc2_api.R` suppresses the plot with a null device); the unexported `get_pars_matrix` was replaced by `get_pars_matrix_oo` (`.emc2_pars_matrix_fn()` in `R/eval/helpers/gof.R` resolves whichever exists); `compare()` gained a `type` argument whose default is now `"conditional"` (the pipeline always passes it explicitly); EMC2 has no LOO/WAIC, so those come from the `loo` package.
- **NEVER call `EMC2::update2version()` on these fits.** It is meant for pre-3.2.0 objects and truncates `attr(dadm, "expand")`, so the likelihood then covers only about 1/4 of the trials. Fits made under 3.4.1 work under 3.5.0 as they are (covered by `test_fitted_fixture.R`).
- **Convergence never passes on non-finite values**: a non-finite or missing Rhat/ESS fails the gate and the verdict (convergence table columns `n_nonfinite_rhat`, `n_nonfinite_ess`); descriptive groups read NA.
- **GoF tables** (`R/eval/goodness_of_fit.R`): the DIC/BPIC table is wide, each IC column twice with `_conditional` / `_joint` suffixes (both `compare()` types). `mean_LL_joint` includes the group-level density, so it is not a data log-likelihood. EMC2 3.4.1's `IC()` had a min/max bug (upstream issue 155), so DIC/BPIC tables cached under 3.4.1 are not comparable on the minD-derived columns. The Bayes-factor option was removed. LOO uses `loo` with `r_eff` and per-chain striding of draws; the pairwise comparison requires identical subjects and per-subject trial counts and is skipped when fewer than two models are available.
- **Recovery eval** (`R/eval/recovery.R`): besides the subject tables it writes `recovery_emc2_stats` (EMC2 `recovery()` per sim x parameter: pearson, spearman, rmse, coverage) and adds `coverage95` to `recovery_subject_stats`; both coverage columns are percentages (0 to 100). Set `ALLOW_PARTIAL_RECOVERY <- TRUE` (or `ALLOW_PARTIAL_PPC <- TRUE` for `R/eval/ppc.R`) as R variables before sourcing the driver to turn fatal missing/unreadable-input errors into partial runs. The source-fit lookup uses `model_rds_pattern()`.
- **PPC**: the per-subject test is Kolmogorov-Smirnov and its FDR threshold is `PPC_KS_ALPHA` (formerly `PPC_AD_ALPHA`). Simulated RTs (recovery and PPC) are untruncated by default; set `SIM_RT_WINDOW <- c(min, max)` in `fit_config.R` (inclusive, like `filter_data()`) to drop simulated trials outside it (`truncate_to_window()` in `R/fit/helpers/recovery.R`; the dropped fraction is logged overall and per subject; the true alpha is saved before the refit and is unaffected; the likelihood stays untruncated; the window is recorded as attribute `rt_window` of the PPC `.rds` (NA = untruncated) and in the `provenance` attribute of `true_alpha`). In the cached `analysis1` PPC simulations 0.19% of simulated RTs fell below 0.23 s and none above 1.0 s. The PPC condition cells are the `PPC_GROUP_VARS` combinations (`eval_config.R`, default `experiment`, `cue_size`, `search_difficulty`; pre-settable): `compute_choice_proportions()`/`compute_qpf_table()` take `group_vars`, and the figures' x variables are the grouping variables other than `experiment`. A model whose script cannot be found (needed to load its data) is fatal in `R/eval/ppc.R` even with `ALLOW_PARTIAL_PPC`.
- **Bayes factors** (`R/eval/bayes_factors.R`, helpers in `R/eval/helpers/bf.R`): bridge-sampling log marginal likelihood (MLL) via `emc_bridge_sampling()` (`EMC2::run_bridge_sampling(emc, stage, filter, repetitions, cores_for_props, cores_per_prop, both_splits)` returns a numeric vector of length `repetitions`). One MLL file per fit, `outputs/models/fit_bf/YYMMDD_<stem>_mll.rds` (`<stem>` = `model_name_from_rds()` of the fit file; a list `model, fit_file, fit_md5, emc2_version, reps, seed, mll, n_split_warnings`), written by `fit_bf_cloud.R` (`scripts/run_bf.sh`; syncs to `results/bf/`). `read_mll()` uses a file only if its `fit_file` is the fit's current file name AND its `fit_md5` matches the file's content (same-day refits/resumes keep the name) AND its `reps` is at least the requested `BF_REPS`. `get_mll()` otherwise stops (naming the cause, from `mll_status()`: no file / other fit file name / md5 mismatch / too few reps), unless the pre-settable `ALLOW_LOCAL_MLL <- TRUE`, which computes locally (hours; sets `RNGkind(RNG_KIND)` + seed like the cloud runner) and writes the file. `compute_mll()` counts and muffles EMC2's "split estimates off by 1 log point" warning (unstable chains) as `n_split_warnings`, surfaced in the `bf_table()` and model-recovery MLL tables. The driver (`BF_REPS`, `BF_REFERENCE` (NULL = highest median MLL), cache key = model files + `BF_REPS` + reference + EMC2 version) writes `outputs/evaluation/bayes_factors/bayes_factors.{rds,csv}` (`bf_table()`: MLL median/min/max/sd, `log_bf_*` vs the reference (min/max = conservative envelope over repetition pairs), `post_prob`). `compare()` does not compute Bayes factors; DIC/BPIC/LOO are unchanged.
- **Model recovery**: `fit_recovery_cloud.R --fit-model-script <path>` refits the data simulated from the fit given as `<extended_rds>` with another model. File names come from `recovery_stem()` (`R/eval/helpers/io.R`): same model `<gen>_recovery_sim<N>`, other model `<gen>_recovery_sim<N>_fit_<MODEL_NAME of the script>` (+ optional `--suffix`), so cross fits never clobber same-model ones and `R/eval/recovery.R` (exact-name regex) reads only same-model fits. `R/eval/model_recovery.R` (helpers `R/eval/helpers/model_recovery.R`) takes the MLLs (`get_mll()`) of every generating x sim x candidate fit, selects the max-median-MLL candidate (`select_by_mll()`; its `margin` = best minus runner-up median MLL, `spread` = the larger repetition range of the two, so margin < spread is a near-tie), requires the candidates of a generating x sim group to share identical `true_alpha` files (`recovery_group_problem()`; incl. `provenance` attribute: source fit, sim seed, `rt_window`, template-data fingerprint `data_fingerprint()` = nrow + md5; a mismatch or a missing fit/true_alpha is fatal unless `ALLOW_PARTIAL_MODEL_RECOVERY`, which skips the group and warns listing each), and writes `model_recovery_{mll,selection,confusion}.{rds,csv}` + `model_recovery_confusion.png` (`plot_confusion_matrix()`) under `outputs/evaluation/model_recovery/`. `N_SIMS` (default 3; also in `R/eval/recovery.R`) and `ALLOW_PARTIAL_MODEL_RECOVERY` are pre-settable.
- Avoid the em-dash (-) in any text destined for academic outputs; use `-` or en-dash (–) instead. This is a per-user writing rule.
- **`docs/` is LOCAL-ONLY and must NEVER be git-tracked or pushed** (gitignored in `.gitignore`). It holds user-facing deliverables (PI decks, reports, methods notes, reference slides) that the user wants visible **only on their machine**, never on GitHub. The same applies to `_deckbuild/` (deck-generating code/deps). Do NOT `git add` or commit these directories, and do not remove them from `.gitignore`, even if asked to "merge them into main" - confirm first, because the user's intent is local visibility, not version control. When writing a report/deck for the user, save it under the **main checkout's** `docs/` (`<repo-root>/docs/`, not a worktree) so it is visible to them while staying untracked.

## Known issues (deferred)

### `EMC2::design()` is intrinsically slow (L2 runs nightly, not per-push)

`EMC2::design()` is ~minutes per model with the PAF LBA spec, on both synthetic and real data. It is dominated by EMC2 evaluating the custom design `functions` (the `SearchDifficulty`/`StimulusAtLoc`/`CueAtLoc`/`PrevTargetAtLoc` closures) over its design grid; it is **not** row-count-driven (a tiny fixture is just as slow). Real fits absorb this one-time cost inside multi-hour MCMC runs. Consequences for testing:
- L2 builds the synthetic model **once** and reuses it across all its assertions (`test_recovery_build.R`); everything else at L2 runs on the committed fitted fixture, with no build.
- L2 is **off the per-push gate**, on nightly + manual dispatch (`.github/workflows/build.yml`); L1 is the fast per-push gate.

`SearchDifficulty()` now classifies each distinct `S` string once (`unique()` + `match()`) instead of once per row; one build of the synthetic model takes ~5 min locally. Further `design()` optimization is deferred: it touches the modeling code used by real fits, so it needs careful behavior-preserving validation.

---

## Cloud infrastructure (AWS, us-east-1)

### Credentials & access
- SSH key path (local): `$HOME\Documents\projects\__secrets__\paf-key.pem`
- SSH key name (AWS): `paf-key`
- IAM user: `paf-cli` (EC2FullAccess, S3FullAccess, IAMFullAccess)

### AWS resources
- S3 bucket: `jon-nir` — PAF files live under the `paf-models/` prefix (i.e. `s3://jon-nir/paf-models/`). The cloud scripts use `$BUCKET` as the path root in `s3://$BUCKET/...`, so set **`BUCKET=jon-nir/paf-models`** (no script change needed; helpers.sh's default is still a placeholder).
- Security group: `paf-sg` (inbound SSH port 22 open); resolve ID at runtime (see boilerplate below)
- IAM instance profile: `paf-ec2-profile` (role: `paf-ec2-role`, S3FullAccess) — attach to every EC2 launch
- AMI: `ami-00403f401ee6a4b98` (Ubuntu 22.04 LTS, us-east-1)

### Instance types
- **Recovery / production**: `c6a.4xlarge` (16 vCPU, 32 GB, ~$0.30/hr spot)
- **Smoke test**: `c5.xlarge` (4 vCPU, 8 GB, ~$0.17/hr on-demand)

### Spot quotas
- Standard spot: 64 vCPUs (approved)
- On-demand standard: 16 vCPUs (default)
- **Always ask the user whether to use On-Demand or Spot before launching any instance.**

### S3 bucket layout (`s3://jon-nir/paf-models/`)
```
inputs/
  data/
    exp1/Exp1_clean.csv             ← raw experiment 1 data (input to load_data())
    exp2/Exp2_clean.csv             ← raw experiment 2 data (input to load_data())
  fit/
    YYMMDD_<name>.rds               ← saved fits (resume inputs for run_fit.sh; recovery/ppc inputs)
results/
  fit/                              ← fit outputs (written by scripts/run_fit.sh)
  recovery/                         ← recovery outputs (written by scripts/run_recovery.sh)
  ppc/                              ← PPC outputs (written by scripts/run_ppc.sh)
```
`run_fit.sh --model-script ...` builds fresh from `inputs/data/`; `run_fit.sh --resume <rds>` pulls from `inputs/fit/`.

### PowerShell session boilerplate
Run at the start of each AWS session:
```powershell
# Resolve security group ID
$SG_ID = aws ec2 describe-security-groups --filters "Name=group-name,Values=paf-sg" `
           --query "SecurityGroups[0].GroupId" --output text

# Write spot-options file (avoids PowerShell JSON quoting issues)
'{"MarketType":"spot"}' | Out-File -Encoding ascii "$env:TEMP\spot-options.json"
```

Then launch a spot instance with:
```powershell
aws ec2 run-instances `
  --image-id ami-00403f401ee6a4b98 `
  --instance-type <type> `
  --key-name paf-key `
  --subnet-id <subnet-id> `
  --security-group-ids $SG_ID `
  --iam-instance-profile Name=paf-ec2-profile `
  --associate-public-ip-address `
  --instance-market-options "file://$env:TEMP\spot-options.json" `
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=<name>}]" `
  --query "Instances[0].InstanceId" --output text
```

**JSON args in PowerShell**: inline JSON strings are mangled by PowerShell's quote handling. Always write to a file with `-Encoding ascii` (not `utf8` — that adds a BOM) and pass via `file://`.

## Archived code

Superseded code was removed from `main` and lives on the **`archive/legacy-python`** branch (pushed to `origin`). It is **not** part of the current pipeline -- do not import from it or treat it as a pattern for current work. Retrieve a file with `git checkout archive/legacy-python -- <path>`, or browse the branch on GitHub.

The branch is a frozen snapshot of `main` as of the pre-cleanup commit `07a726c`. It holds four interdependent groups (one dependency chain rooted at `enum_types.py`, so the branch is internally consistent and runnable as a unit):

- `__exploratory/__do_not_use/` - old raw-data loaders and ad-hoc notebooks.
- `__exploratory/LATER/` - LATER-model exploratory notebooks (`check_assumptions.ipynb`, `pooled_results.ipynb`).
- `__exploratory/hssm_models/` - custom-coded HSSM (PyMC) LBA models; superseded by the native LBA implementation in `R::EMC2`.
- `enum_types.py`, `load_data.py`, `playground.py` - the legacy Python data pipeline (canonical factor-level enums, CSV loaders/design-matrix builder, and the `emc2_design_matrix.csv` generator); superseded by the R-native `load_data()` in `R/helpers/data.R`.
