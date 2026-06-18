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
Rscript R/fit/fit_initial.R                        # full batch: fit model1..model5 for INITIAL_FIT_SAMPLES iterations
Rscript R/fit/fit_extend_local.R                   # extend locally (2 models in parallel if cores allow)
Rscript R/fit/fit_extend_local.R --sequential      # extend locally, force sequential
Rscript R/fit/fit_extend_cloud.R <rds_filename>    # single-model cloud extend (called by scripts/run_extend.sh)
source("R/eval/examine_model.R")                   # inspect a single fitted model
source("R/eval/diagnostics.R")                     # convergence diagnostics + GoF comparison across all models
```

R (tests; requires `testthat` - `install.packages("testthat")`):
```
Rscript __tests__/run_tests.R                    # level 1: helpers unit tests (<5 s, no EMC2)
TEST_LEVEL=2 Rscript __tests__/run_tests.R       # level 2: + model build tests (requires EMC2)
TEST_LEVEL=3 Rscript __tests__/run_tests.R       # level 3: + fit smoke tests (CI only, hours)
```

**Tiered testing strategy.** The suite is tiered by cost and intent; a higher TEST_LEVEL always runs the lower tiers too.

| Tier | Dir | Scope | Cost | When |
|---|---|---|---|---|
| L1 | `__tests__/helpers/` | Unit tests for pure helpers (logging, data, fitting helpers, recovery helpers). No EMC2 required. | <5 s total | Every push/PR (CI auto). |
| L2 | `__tests__/models/` | Integration tests: `make_emc()` for all 5 models, plus the recovery extract→simulate→build chain. Uses committed fixture; no MCMC sampling. Each model is built **once** and reused across its assertions (the build is dominated by `EMC2::design()`, ~minutes per model). | ~tens of min | Nightly + manual dispatch (CI). |
| L3 | `__tests__/fit/` | End-to-end smoke tests with tiny MCMC (n_chains=2, iter=5). One file (`test_fit_smoke.R`) covers three pipelines: **Smoke A** = `fit_initial`, **Smoke B** = `extend_model`, **Smoke C** = recovery (extract→simulate→refit). | minutes-hours | Manual dispatch only (CI). |

CI (GitHub Actions):
- L1 runs automatically on every push and on PRs to `main` (`.github/workflows/test.yml`).
- L2 is **not** per-push (intrinsically slow: `EMC2::design()` is ~minutes per model). It runs nightly (03:00 UTC) and on manual dispatch: Actions tab → "Build Tests" → "Run workflow" (`.github/workflows/build.yml`).
- L3 is manual-only: Actions tab → "Smoke Tests" → "Run workflow" (`.github/workflows/smoke.yml`).
- `use-public-rspm: true` serves pre-compiled Linux binaries; EMC2 installs in ~2 min instead of compiling from source.
- Package caches are keyed on `.github/r-deps-level1.txt` / `r-deps-level2.txt` and auto-invalidate when the dep list changes.

When adding a new pipeline, add a unit test at L1 (for any pure helper), a build/structural test at L2 (uses the fixture, no MCMC), and a smoke test at L3 (tiny MCMC end-to-end).

`fit_extend_local.R` reads a **hardcoded list of `.rds` filenames** at the top of the file (`model_files <- c("YYMMDD_model1.rds", ...)`). Edit that list before running.

## Data loading (R-native pipeline)

The pipeline reads raw experiment CSVs directly in R:

1. `R/helpers/data.R` `load_data()` reads `data/exp{1,2}/Exp{1,2}_clean.csv`, applies all column transforms (renaming, distractor-string construction, RT conversion, boolean mapping, cue-size encoding), enforces ordered factors (`search_difficulty` ∈ {EASY < MIXED < DIFFICULT}, `cue_size` ∈ {NONE < SMALL < MEDIUM < LARGE}), and applies RT cutoffs -- returning the same 15-column tibble as before.

`data/` is **gitignored** (see `.gitignore:2`). A fresh clone has no data; the raw cleaned CSVs must be supplied locally.

The earlier Python data pipeline (`load_data.py`, `enum_types.py`, `playground.py`) and its `data/emc2_design_matrix.csv` intermediate were retired and removed from `main`; they live on the `archive/legacy-python` branch (see **Archived code** below).

## Architecture

- **`R/` layout**: split into three layers.
  - `R/config.R` — project-level: RNG (`seed = 42`, `L'Ecuyer-CMRG`), saccade RT cutoffs (0.23 to 1.0 s), the asymmetric convergence thresholds (`MAX_RHAT_MU`/`MIN_ESS_MU` + `MAX_RHAT_ALPHA`/`MIN_ESS_ALPHA`; used by BOTH the fit and eval layers), and output dir paths (`OUTPUTS_DIR`, `MODELS_DIR`, `EVAL_DIR`, `MODELS_{INITIAL,EXTEND,RECOVERY}_DIR`). Sourced (directly or transitively) by every script.
  - `R/utils.R` — `source_root(rel)`, `parse_int_arg`, `parse_str_arg`, `check_valid_string`. Sourced as the FIRST line of every R file via `source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))`.
  - `R/fit/` — fitting code (`fit_*.R`, `model{1..5}.R`) + `R/fit/fit_config.R` (priors, `N_CHAINS = 3`, fit params `INITIAL_FIT_SAMPLES=1000`/`EXTENDED_FIT_SAMPLES=3000`/`MAX_TRIES=20`/`STEP_SIZE=200`/`SAVE_EVERY=2`, recovery params, and the `CONSTANTS = c(sv = log(1))` identifiability anchor). The asymmetric convergence thresholds were relocated to `R/config.R` (shared with eval). Changing a prior here propagates to all 5 models.
  - `R/eval/` — evaluation code: `convergence.R` (step-2.9 convergence table + verdict), `goodness_of_fit.R` (GoF/DIC/BPIC; step-3 scaffolding), `recovery.R` (parameter-recovery analysis), `ppc.R` (step-4 posterior predictive checks), `review_convergence_and_recovery.R` (step-2.9 synthesis), `examine_model.R` (interactive) + `R/eval/eval_config.R`.
  - `R/helpers/` — cross-cutting helpers used by both fit and eval: `logging.R`, `data.R`.
  - `R/fit/helpers/` — fit-only helpers: `build_model.R`, `fitting.R`, `recovery.R`.
  - `R/eval/helpers/` — eval-only helpers: `convergence.R` (Rhat/ESS extraction + verdict), `recovery.R` (recovery-eval computations), `gof.R` (GoF computations), `ppc.R` (PPC computations), `plot.R` (Plotly figures), `io.R` (`load_model`, `save_eval_table`, `newer_than_inputs`).
  - Parallelism (`cores_for_chains`, `cores_per_chain`) is auto-detected at runtime by `get_core_args()` in `R/fit/helpers/fitting.R` — no manual core config is needed.
- **Output locations** (from `R/config.R`):
  - `MODELS_INITIAL_DIR  = "outputs/models/fit_initial"`  — `.rds` files from `fit_initial.R`, named `YYMMDD_<MODEL_NAME>.rds`.
  - `MODELS_EXTEND_DIR   = "outputs/models/fit_extend"`   — `.rds` files from `fit_extend_*.R`.
  - `MODELS_RECOVERY_DIR = "outputs/models/fit_recovery"` — `.rds` files from `fit_recovery_cloud.R`.
  - `EVAL_DIR            = "outputs/evaluation"`          — eval outputs (`convergence.{rds,csv}` from `convergence.R`; `model_comparison.{rds,csv}` from `goodness_of_fit.R`; `review_2_9_summary.{rds,csv}` from the 2.9 synthesis); recovery analysis lands under `outputs/evaluation/parameter_recovery/`.
  - `LOG_FILE` is **not** in `config.R`; each script derives it locally (e.g. `file.path(MODELS_INITIAL_DIR, "log.txt")`). `fit_initial.R` writes to `outputs/models/fit_initial/log.txt`; `fit_extend_*.R` writes per-model logs to `outputs/models/fit_extend/log_extend_<name>.txt`.
- **Model family**: five nested LBA variants (`R/fit/model1.R` .. `model5.R`) differing in the formulas for drift rate `v`, threshold `B`, and between-trial variability `sv`. Each script defines `MODEL_NAME` and a thin `build_model(data, n_chains = 3)` that delegates to `build_lba_model()` in `R/fit/helpers/build_model.R`. `build_lba_model()` owns all shared boilerplate (base priors, `design()`, `prior()`, `make_emc()`); each model passes only its `v_formula`, `B_formula`, and any extra prior entries. To add a new variant, copy `model1.R` and adjust those three arguments.
- **Two-phase fitting**:
  - `R/fit/fit_initial.R` loads data once, then `tryCatch`-wraps each `modelN.R` in turn and fits each for exactly `INITIAL_FIT_SAMPLES` (1000) iterations. **A model failing does not abort the batch** — check `log.txt`, not just the R console, to know whether everything finished.
  - `R/fit/fit_extend_local.R` resumes previously-fit `.rds` files locally, running two models in parallel when the machine has enough cores (`>= 2 * N_CHAINS`), otherwise sequentially. Pass `--sequential` to force sequential mode. Each invocation writes to its own per-model log (`outputs/models/fit_extend/log_extend_<name>.txt`).
  - `R/fit/fit_extend_cloud.R` extends a single model on a cloud VM (one process per machine). Reads `CP_CMD` and `DEST_PREFIX` from the environment and syncs the `.rds` + log to S3/GCS after every try. Called by `scripts/run_extend.sh`.
  - Convergence is checked by `check_block_convergence()` in `R/fit/helpers/fitting.R` using `EMC2::check()` to extract per-parameter Rhat and ESS, then applying `MAX_RHAT_MU`/`MIN_ESS_MU` to the `$mu` block and `MAX_RHAT_ALPHA`/`MIN_ESS_ALPHA` to the pooled `$alpha` block. EMC2's built-in `stop_criteria` is bypassed because it cannot apply different thresholds per block.
- **Factor level orderings**: `R/helpers/data.R` is the single source of truth for the canonical level orderings, encoded through closure functions (`StimulusAtLoc`, `CueAtLoc`, `PrevTargetAtLoc`, `SearchDifficulty`) that EMC2's `design()` calls. (The original Python `enum_types.py` definitions are preserved on the `archive/legacy-python` branch but are no longer authoritative.)
- **Latest-version lookup**: `R/eval/helpers/io.R` `load_model()` parses the `YYMMDD_` prefix and always returns the most recent `.rds` for a given model name.

## Analysis workflow

The research pipeline runs in numbered stages. Steps marked `X.9` (and one `2.4`) are **stop-and-review checkpoints**: Claude must surface diagnostics and prompt a discussion (with PI flagged where noted) rather than auto-proceeding to the next stage. Do not pre-decide outcomes for deferred questions at these checkpoints.

| # | Step | Status |
|---|---|---|
| 0a | PAF predictions pre-registered (notes/paper) | DONE |
| 0b | Pre-hoc exclusion: RT cutoffs (0.23-1.0 s) only; no further subject filter | DONE |
| 1 | `fit_initial.R`: 1000 samples per model | DONE |
| 2 | `fit_extend_local.R` with asymmetric convergence target (see below). All models run to 3000 total iterations. | DONE |
| **2.4** | **Claude-only sanity check**: flag models with severe non-convergence (`$mu` Rhat > 1.1 or ESS < 200). No hard flags triggered. Models 4 and 5 show marginal convergence (soft flags for 2.9 trace-plot review). Model 3 excluded from all further analyses (mechanistically identical to model 4 but less interpretable). Active set: models 1, 2, 4, 5. | DONE |
| 2.5 | **Parameter recovery** -- Replicating Strickland et al. (2026) Supplementary: extract (μ̂, Σ̂) from each extended fit; for each of 3 simulations draw fresh subject parameters via `make_random_effects(design, μ̂, Σ̂)` and simulate data via `make_data()` on the real trial structure; refit each model from scratch using the same priors as the original fits. Evaluate recovery with EMC2's built-in `recovery()` (RMSE + correlation at μ and α levels; Strickland et al. 2026) and posterior z-scores + contraction (Schad, Betancourt & Vasishth 2021). | NEXT |
| **2.9** | **STOP & REVIEW (with PI)**: combined convergence + recovery review. Decide which models survive. | |
| 3 | **Goodness of fit** -- BPIC (screening), DIC (reporting only, not for decisions), PSIS-LOO-CV (primary, with Pareto-k diagnostic), WAIC (confirmatory); no Bayes factors (priors not grounded enough to trust marginal-likelihood ratios). | |
| **3.9** | **STOP & REVIEW (with PI)**: review Pareto-k diagnostics (flag any model with > 10% k > 0.7), check LOO/WAIC agreement, identify candidate winner(s) or co-winners. | |
| 4 | PPC for top model(s): per-subject KS + theory-relevant contrasts on exp1+2. | |
| **4.9** | **STOP & REVIEW**: PPC quality + exp1+2 vs exp3 descriptive comparison (population-shift check). | |
| 5 | OOD test: within-subject prediction. Use trained `$alpha` to simulate exp3 conditions (incl. all-cue: see mechanism below). Compare to empirical exp3. | |
| **5.9** | **STOP & REVIEW (with PI)**: define pass/fail rule (deferred until now), interpret results. | |
| 6 | PPC + OOD for all other accepted models (diagnostic comparison). | |
| 7 | Identifiability spot-check: max pairwise posterior correlation per accepted model. | |
| **7.9** | **STOP & REVIEW**: final synthesis. Joint GoF + OOD ranking, write-up plan. | |
| 8 | Conclude / write up. | |

**Asymmetric convergence target for step 2** (overrides the symmetric defaults in `R/fit/fit_config.R`):

| Block | Rhat | ESS bulk | Notes |
|---|---|---|---|
| `$mu` | < 1.05 | > 500 | Population params reported with CIs; tighter Rhat than EMC2 default. |
| `$alpha` | < 1.1 | > 400 | EMC2-default-aligned; subject-level params feed OOD simulation. |
| `$sigma2` | descriptive only | descriptive only | Not used in prediction under within-subject OOD design. |
| `$correlation` | descriptive only | descriptive only | Routinely non-convergent in hierarchical LBA; report as known limitation. |

This is implemented in `check_block_convergence()` in `R/fit/helpers/fitting.R`: `stop_criteria` is evaluated only on `$mu` + `$alpha` rows of the Rhat/ESS tables, not the full parameter set.

**All-cue prediction mechanism (step 5)**: exp3 introduces a novel "all-cue" condition (the same visual cue shown at all 4 locations simultaneously). The trained LBA model handles this without retraining: set `CueAtLoc=X` on **all 4 accumulators** rather than one cued and three NONE. The additive linear LBA then predicts (a) uniformly faster RTs, (b) no location bias, (c) linear speedup vs. single-cue. Any of these failing in empirical exp3 is informative falsification (attention-splitting, saturation, or non-additive cue combination).

**Deferred decisions** (do NOT pre-decide; resolve at the listed checkpoint):
- OOD contrast pass/fail rule → resolve at 5.9.
- `$sigma2` non-convergence acceptance for models 4-5 → resolve at 2.9.

**No forced single winner**: GoF and OOD rankings are reported jointly. The analysis may legitimately conclude with co-winners or with different "best" models for different criteria.

**Compute envelope through step 5** (parallel cloud, spot pricing): ~$200-300, ~3-4 weeks wall-clock.

## Important files

Project-level:
- `R/config.R` - RNG, RT cutoffs, paths (`OUTPUTS_DIR`, `MODELS_*_DIR`, `EVAL_DIR`, `DATA_DIR`)
- `R/utils.R` - `source_root()` plus `parse_int_arg`, `parse_str_arg`, `check_valid_string`
- `R/helpers/logging.R` - timestamped logging, error reporting, config serialisation
- `R/helpers/data.R` - **entry point `load_data()`** reads raw CSVs end-to-end; `filter_data()` for custom RT cutoffs on an already-loaded tibble; EMC2 factor closures (`StimulusAtLoc`, `CueAtLoc`, `PrevTargetAtLoc`, `SearchDifficulty`); sources `logging.R`

Fitting (`R/fit/`):
- `R/fit/fit_config.R` - priors, `N_CHAINS`, fit params, recovery params, `CONSTANTS` (asymmetric convergence thresholds now in `R/config.R`)
- `R/fit/fit_initial.R` - master batch fit
- `R/fit/fit_extend_local.R` - local batch extend (2 models in parallel if cores allow; `--sequential` flag to override)
- `R/fit/fit_extend_cloud.R` - cloud single-model extend (called by `scripts/run_extend.sh`)
- `R/fit/fit_recovery_cloud.R` - cloud single-sim parameter recovery (called by `scripts/run_recovery.sh`)
- `R/fit/fit_ppc_cloud.R` - cloud posterior predictive simulation (called by `scripts/run_ppc.sh`)
- `R/fit/model1.R` - canonical template for a model variant (thin wrapper; see `build_lba_model()` in `helpers/build_model.R`)
- `R/fit/helpers/build_model.R` - `build_lba_model()` factory; sources `fit_config.R` and `R/helpers/data.R`
- `R/fit/helpers/fitting.R` - `get_core_args`, `save_model`, `check_block_convergence`, `extend_model`, `model_log_path`; sources `build_model.R`. **Single entry point for fit scripts**.
- `R/fit/helpers/recovery.R` - `extract_group_params`, `extract_design`, `simulate_recovery_data`; sources `fitting.R`.

Evaluation (`R/eval/`):
- `R/eval/eval_config.R` - eval params + `RECOVERY_EVAL_DIR` (currently minimal)
- `R/eval/convergence.R` - step-2.9 convergence table + verdict (writes `convergence.{rds,csv}`)
- `R/eval/goodness_of_fit.R` - GoF/model comparison (DIC/BPIC; step-3 scaffolding; writes `model_comparison.{rds,csv}`)
- `R/eval/recovery.R` - load `_extended` recovery fits, produce population table + subject scatter + z-score/contraction plots
- `R/eval/ppc.R` - step-4 posterior predictive checks (per-subject KS + theory contrasts)
- `R/eval/review_convergence_and_recovery.R` - step-2.9 synthesis (joins convergence verdict + recovery; writes `review_2_9_summary.{rds,csv}`)
- `R/eval/examine_model.R` - inspect a single fitted model
- `R/eval/helpers/convergence.R` - Rhat/ESS extraction, `create_convergence_table()`, `add_convergence_verdict()`
- `R/eval/helpers/recovery.R` - recovery-eval computations (prior-SD extraction, z-score/contraction, RMSE/r)
- `R/eval/helpers/gof.R` - goodness-of-fit computations (DIC/BPIC/LOO/WAIC)
- `R/eval/helpers/ppc.R` - PPC computations (per-subject KS, theory contrasts)
- `R/eval/helpers/plot.R` - Plotly figure builders + `save_plotly_png()` (PNG export with HTML fallback)
- `R/eval/helpers/io.R` - `load_model()`, `save_eval_table()`, `newer_than_inputs()` (shared eval I/O)

Other:
- `scripts/helpers.sh` - shared config defaults and cloud copy helpers (sourced by the scripts below)
- `scripts/vm_setup.sh` - one-time R + EMC2 install on a fresh Ubuntu VM
- `scripts/run_extend.sh` - download initial .rds, run `fit_extend_cloud.R`, sync results
- `scripts/run_recovery.sh` - download extended .rds, run `fit_recovery_cloud.R`, sync results
- `scripts/run_ppc.sh` - download extended .rds, run `fit_ppc_cloud.R`, sync results
- `__tests__/run_tests.R` - test entry point; gated by `TEST_LEVEL` env var (1/2/3)
- `__tests__/fixtures/sample_data.csv` - committed synthetic design matrix (~240 rows)
- `__tests__/helpers/` - L1 unit tests (logging, data, model helpers, recovery helpers; no EMC2)
- `__tests__/models/` - L2 build tests (`make_emc()` for all 5 models + recovery build chain; requires EMC2)
- `__tests__/fit/test_fit_smoke.R` - L3 smoke tests; covers Smoke A (`fit_initial`), Smoke B (`extend_model`), Smoke C (recovery). CI manual dispatch only. Smoke C uses bounded `stop_criteria` (`max_gd=Inf`) so all EMC2 phases exit after a fixed iteration count — runtime is deterministic on all platforms (~7-10 min on Windows with `cores_for_chains=1`).
- `.github/workflows/test.yml` - CI: L1 unit tests (auto on push/PR to `main`)
- `.github/workflows/build.yml` - CI: L2 build tests (nightly 03:00 UTC + manual dispatch)
- `.github/workflows/smoke.yml` - CI: L3 smoke tests (manual dispatch only)
- `.github/r-deps-level1.txt` / `r-deps-level2.txt` - package lists used by CI cache keys

## Gotchas

- Running an R script with the wrong cwd silently fails on the first `source("R/config.R")`. Always start from the repo root.
- Per-model failures are caught by `tryCatch` in `fit_initial.R` so the batch keeps going. Treat `outputs/models/fit_initial/log.txt` as authoritative for run status, not stdout.
- `CONSTANTS = c(sv = log(1))` in `config.R` is an **identifiability anchor** for the LBA. Removing or changing it will silently make the model non-identifiable.
- Dependencies are not pinned in any manifest. R: `EMC2`, `dplyr`, `readr`, `tools`, `testthat`. (The retired Python pipeline's deps are documented on the `archive/legacy-python` branch.)
- R environment on the local machine:
  - `R_HOME = C:\Program Files\R\R-4.5.2`
  - `R_LIBS_USER = C:\Users\nirjo\R_library\4.5`
  - The system library under `R_HOME` is not writable; install packages to `R_LIBS_USER`.
  - The pattern `file.path(Sys.getenv("USERPROFILE"), "R", "library")` used in some test files resolves to the wrong path on this machine (`C:\Users\nirjo\R\library` vs the actual `R_LIBS_USER`).
  - **Running `Rscript` from the Bash tool: set `R_LIBS_USER` first.** Bare `Rscript` falls back to the Claude app's sandboxed R library (`AppData/Local/Packages/Claude_.../R/win-library/4.5`) which has an older `rlang` that conflicts when loading `readr`/`EMC2`. Prefixing with `R_LIBS_USER="C:/Users/nirjo/R_library/4.5"` puts the user library first and `readr`/`dplyr`/`EMC2 3.4.1` load cleanly (verified). The PATH `Rscript` is already the real `R-4.5.2`. Recipe: `R_LIBS_USER="C:/Users/nirjo/R_library/4.5" Rscript <script>`. **eval/check/recovery analysis can run locally this way; heavy MCMC fitting still belongs on the cloud.** Note: `outputs/` and `data/` live in the main checkout, not the worktree — run eval from the main-repo cwd with `PAF_REPO_ROOT` pointed at the worktree to use edited code against real data.
- **EMC2 API / object structure reference**: https://www.rdocumentation.org/packages/EMC2/versions/3.3.0 (function docs for `check()`, `get_pars()`, `recovery()`, `make_data()`, `make_random_effects()`, etc.). The rdocumentation mirror is for 3.3.0; the local install is **3.4.1**, so verify against the installed version if a signature or return shape differs. Empirically confirmed shapes (3.4.1): `check()` returns per-block `chk[[g]][[g]]` as a 2-row matrix (row 1 Rhat, row 2 ESS), with `chk$alpha` a per-subject list of such matrices; `get_pars(selection="mu")` returns an mcmc.list; `get_pars(selection="alpha", return_mcmc=TRUE)` is **parameter-keyed** (list of length n_pars, each `[samples x subjects]`); `prior$theta_mu_var` holds the population-mean prior covariance (`sqrt(diag(.))` = prior SDs); `recovery(do_plot=FALSE)` returns a per-parameter list with `$stats` (pearson/spearman/rmse/coverage) and `$quantiles`.
- Avoid the em-dash (-) in any text destined for academic outputs; use `-` or en-dash (–) instead. This is a per-user writing rule.
- **`docs/` is LOCAL-ONLY and must NEVER be git-tracked or pushed** (gitignored in `.gitignore`). It holds user-facing deliverables (PI decks, reports, methods notes, reference slides) that the user wants visible **only on their machine**, never on GitHub. The same applies to `_deckbuild/` (deck-generating code/deps). Do NOT `git add` or commit these directories, and do not remove them from `.gitignore`, even if asked to "merge them into main" - confirm first, because the user's intent is local visibility, not version control. When writing a report/deck for the user, save it under the **main checkout's** `docs/` (`<repo-root>/docs/`, not a worktree) so it is visible to them while staying untracked.

## Known issues (deferred)

### L2 build tests — `'listgreater'` and assertion bugs RESOLVED; `design()` is slow (L2 now nightly)

History (all resolved): L2 (`test_build_models.R`) errored for a long time inside `EMC2::design()` with `unimplemented type 'list' in 'listgreater'`. **Root cause was the test fixture**: the old `sample_data.csv`/`generate_fixture.R` emitted each trial **4x-duplicated** (one row per accumulator) with only 11 columns, whereas `load_data()` returns **one row per trial** with 15 columns and EMC2's `design()`/`add_accumulators()` does the per-`lR` expansion itself. Feeding pre-expanded rows corrupted the accumulator ordering. Regenerating the fixture as a faithful one-row-per-trial, 15-column matrix fixed it. Once `design()` succeeded, two pre-existing bugs in `__tests__/models/shared_assertions.R` surfaced and were fixed: `expect_type()`/`expect_setequal()` were being passed an unsupported `label=` arg, and `expect_prior_mean()` read `prior$mu_mean` instead of `prior$theta_mu_mean` (the EMC2 3.4.1 field).

**Remaining characteristic (not a bug): `EMC2::design()` is intrinsically slow** with the PAF LBA spec — ~minutes per model, on both synthetic and real data (measured: ~10 min for `design()` on a 300-row real slice locally; CI build-tests were ~8 min/build). It is dominated by EMC2 evaluating the custom design `functions` (the `SearchDifficulty`/`StimulusAtLoc`/`CueAtLoc`/`PrevTargetAtLoc` closures) over its design grid; it is not row-count-driven (a 16-row fixture is just as slow). The real fits tolerate this one-time cost inside multi-hour MCMC runs. Consequences for testing:
- L2 now builds each model **once** and reuses it across that model's assertions (`test_build_models.R`, `test_recovery_build.R`), cutting ~23 builds → ~5 (+2 for recovery). Suite is ~tens of minutes.
- L2 was moved **off the per-push gate** to nightly + manual dispatch (`.github/workflows/build.yml`); L1 remains the fast per-push gate.

**Deferred (not now):** optimizing `design()` itself (e.g. vectorizing the `SearchDifficulty` closure). This touches the modeling code used by real fits, so it needs careful behavior-preserving validation and was deliberately not attempted as part of the test cleanup.

**Status**: not blocking the analysis pipeline (recovery/fit/extend work end-to-end via L3 smoke tests). Next: confirm a green L2 on the nightly/manual `build.yml` run.

---

## Cloud infrastructure (AWS, us-east-1)

### Credentials & access
- SSH key path (local): `$HOME\Documents\projects\__secrets__\paf-key.pem`
- SSH key name (AWS): `paf-key`
- IAM user: `paf-cli` (EC2FullAccess, S3FullAccess, IAMFullAccess)

### AWS resources
- S3 bucket: `paf-models`
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

### S3 bucket layout (`s3://paf-models/`)
```
inputs/
  data/
    exp1/
      Exp1_clean.csv                ← raw experiment 1 data (input to load_data())
    exp2/
      Exp2_clean.csv                ← raw experiment 2 data (input to load_data())
  fit_extend/
    260525_model1_extended.rds      ← extended fits (recovery inputs)
    260525_model2_extended.rds
    260525_model4_extended.rds
    260525_model5_extended.rds
results/
  recovery/                         ← recovery outputs (written by scripts/run_recovery.sh)
```
`inputs/fit_initial/` is also supported by `scripts/run_extend.sh` but those files are not currently staged.

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
