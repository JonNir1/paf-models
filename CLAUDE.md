# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bayesian hierarchical cognitive modeling of the **PAF (Priority Accumulation Framework)** theory of visual attention, fit to saccade-latency data from two visual-search experiments. Bilingual:

- **Python** ingests and reshapes the raw experimental CSVs into a single EMC2-ready design matrix.
- **R + `EMC2`** fits a family of hierarchical LBA (Linear Ballistic Accumulator) models and runs model comparison.

## Run from the repo root

Every R `source()` and every Python relative import assumes the **repo root** as the working directory (e.g. `source("R/config.R")` appears inside scripts that themselves live under `R/`). Do not `cd` into a subdirectory before running anything.

## Common commands

There is **no linter or build system**. A `testthat` test suite lives in `__tests__/`. Verifying a change: run the relevant script AND the appropriate test level below.

Python (data pipeline):
```
python load_data.py        # loads + filters Exp1, Exp2 in-memory
python playground.py       # regenerates data/emc2_design_matrix.csv
```

R (modeling pipeline; from a fresh R session at repo root):
```
Rscript R/model_fitting/fit_initial.R                        # full batch: fit model1..model5 for INITIAL_FIT_SAMPLES iterations
Rscript R/model_fitting/fit_extend_local.R                   # extend locally (2 models in parallel if cores allow)
Rscript R/model_fitting/fit_extend_local.R --sequential      # extend locally, force sequential
Rscript R/model_fitting/fit_extend_cloud.R <rds_filename>    # single-model cloud extend (called by cloud_setup.sh)
source("R/model_fitting/examine_model.R")   # inspect a single fitted model
source("R/analysis/compare_models.R")       # diagnostics + GoF comparison across all 5 models
```

R (tests; requires `testthat` - `install.packages("testthat")`):
```
Rscript __tests__/run_tests.R                    # level 1: helpers unit tests (<5 s, no EMC2)
TEST_LEVEL=2 Rscript __tests__/run_tests.R       # level 2: + model build tests (requires EMC2)
TEST_LEVEL=3 Rscript __tests__/run_tests.R       # level 3: + fit smoke tests (CI only, hours)
```

CI (GitHub Actions):
- L1 + L2 run automatically on every push and on PRs to `main` (`.github/workflows/test.yml`).
- L3 is manual-only: Actions tab → "Smoke Tests" → "Run workflow" (`.github/workflows/smoke.yml`).
- `use-public-rspm: true` serves pre-compiled Linux binaries; EMC2 installs in ~2 min instead of compiling from source.
- Package caches are keyed on `.github/r-deps-level1.txt` / `r-deps-level2.txt` and auto-invalidate when the dep list changes.

`fit_extend_local.R` reads a **hardcoded list of `.rds` filenames** at the top of the file (`model_files <- c("YYMMDD_model1.rds", ...)`). Edit that list before running.

## Data handoff (Python -> R)

The Python and R sides communicate through one file:

1. `load_data.py:46` `load_as_emc2_design_matrix()` reads `data/exp{1,2}/Exp{1,2}_clean.csv`, applies `enum_types.py` mappings, and produces a DataFrame.
2. `playground.py` writes it to `data/emc2_design_matrix.csv`.
3. `R/model_fitting/helpers/data.R` `load_safe_csv()` reads that CSV and enforces ordered factors: `search_difficulty` ∈ {EASY < MIXED < DIFFICULT}, `cue_size` ∈ {NONE < SMALL < MEDIUM < LARGE}.

`data/` is **gitignored** (see `.gitignore:2`). A fresh clone has no data; the cleaned CSVs and the design matrix must be supplied locally.

## Architecture

- **`R/config.R`** is the single source of truth for: RNG (`seed = 42`, `L'Ecuyer-CMRG`), saccade RT cutoffs (0.23 to 1.0 s), `N_CHAINS = 3` (MCMC chains baked into each model at `make_emc()` time; cannot be changed after fitting), fitting params (`INITIAL_FIT_SAMPLES = 1000`, `EXTENDED_FIT_SAMPLES = 3000`, `MAX_TRIES = 20`, `STEP_SIZE = 100`, `SAVE_EVERY = 2`) plus per-block convergence thresholds (`MAX_RHAT_MU`/`MIN_ESS_MU` and `MAX_RHAT_ALPHA`/`MIN_ESS_ALPHA`), every prior (`V_*`, `B_*`, `A_*`, `T0_*`, `SV_*`), and the `CONSTANTS = c(sv = log(1))` identifiability anchor. Changing a prior here propagates to all 5 models. Parallelism (`cores_for_chains`, `cores_per_chain`) is auto-detected at runtime by `get_core_args()` in `helpers/fitting.R` — no manual core config is needed.
- **Output locations** (also from `config.R`):
  - `MODELS_INITIAL_DIR = "emc2_models/fit_initial"` holds `.rds` files from `fit_initial.R`, named `YYMMDD_<MODEL_NAME>.rds`.
  - `MODELS_EXTEND_DIR = "emc2_models/fit_extend"` holds `.rds` files from `fit_extend_*.R`.
  - `LOG_FILE` is **not** in `config.R`; each script derives it locally (e.g. `file.path(MODELS_INITIAL_DIR, "log.txt")`). `fit_initial.R` writes to `emc2_models/fit_initial/log.txt`; `fit_extend_*.R` writes per-model logs to `emc2_models/fit_extend/log_extend_<name>.txt`.
  - `RESULTS_DIR = "Results"` holds the comparison RDS files (`model_comparison_diagnostics.rds`, `model_comparison_fit.rds`).
- **Model family**: five nested LBA variants (`R/model_fitting/model1.R` .. `model5.R`) differing in the formulas for drift rate `v`, threshold `B`, and between-trial variability `sv`. Each script defines `MODEL_NAME` and a thin `build_model(data, n_chains = 3)` that delegates to `build_lba_model()` in `helpers.R`. `build_lba_model()` owns all shared boilerplate (base priors, `design()`, `prior()`, `make_emc()`); each model passes only its `v_formula`, `B_formula`, and any extra prior entries. To add a new variant, copy `model1.R` and adjust those three arguments.
- **Two-phase fitting**:
  - `R/model_fitting/fit_initial.R` loads data once, then `tryCatch`-wraps each `modelN.R` in turn and fits each for exactly `INITIAL_FIT_SAMPLES` (1000) iterations. **A model failing does not abort the batch** - check `log.txt`, not just the R console, to know whether everything finished.
  - `R/model_fitting/fit_extend_local.R` resumes previously-fit `.rds` files locally, running two models in parallel when the machine has enough cores (`>= 2 * N_CHAINS`), otherwise sequentially. Pass `--sequential` to force sequential mode. Each invocation writes to its own per-model log (`emc2_models/log_extend_<name>.txt`).
  - `R/model_fitting/fit_extend_cloud.R` extends a single model on a cloud VM (one process per machine). Reads `CP_CMD` and `DEST_PREFIX` from the environment and syncs the `.rds` + log to S3/GCS after every try. Called by `cloud_setup.sh do_run`.
  - Convergence is checked by `check_block_convergence()` in `R/model_fitting/helpers/fitting.R` using `EMC2::check()` to extract per-parameter Rhat and ESS, then applying `MAX_RHAT_MU`/`MIN_ESS_MU` to the `$mu` block and `MAX_RHAT_ALPHA`/`MIN_ESS_ALPHA` to the pooled `$alpha` block. EMC2's built-in `stop_criteria` is bypassed because it cannot apply different thresholds per block.
- **Enum to factor bridge**: `enum_types.py` defines the canonical level orderings (`LocationTypeEnum`, `DistractorTypeEnum`, `SearchDifficultyTypeEnum`, `CueSizeTypeEnum`, `SideTypeEnum`). R does **not** import these. Instead, `R/model_fitting/helpers/data.R` re-encodes them through closure functions (`StimulusAtLoc`, `CueAtLoc`, `PrevTargetAtLoc`, `SearchDifficulty`) that EMC2's `design()` calls. Adding or renaming a factor level requires changes on **both** sides.
- **Latest-version lookup**: `R/analysis/compare_models.R:23` `load_model()` parses the `YYMMDD_` prefix and always returns the most recent `.rds` for a given model name.

## Analysis workflow

The research pipeline runs in numbered stages. Steps marked `X.9` (and one `2.4`) are **stop-and-review checkpoints**: Claude must surface diagnostics and prompt a discussion (with PI flagged where noted) rather than auto-proceeding to the next stage. Do not pre-decide outcomes for deferred questions at these checkpoints.

| # | Step | Status |
|---|---|---|
| 0a | PAF predictions pre-registered (notes/paper) | DONE |
| 0b | Pre-hoc exclusion: RT cutoffs (0.23-1.0 s) only; no further subject filter | DONE |
| 1 | `fit_initial.R`: 1000 samples per model | DONE |
| 2 | `fit_extend_local.R` with asymmetric convergence target (see below). Runs 2 models in parallel locally. | NEXT |
| **2.4** | **Claude-only sanity check**: flag models with severe non-convergence (`$mu` Rhat > 1.1 or ESS < 200). If flagged, ping user before launching 2.5. | |
| 2.5 | Parameter recovery: 3 sims × 4 models, parallel cloud, post-extend posterior means as ground truth. | |
| **2.9** | **STOP & REVIEW (with PI)**: combined convergence + recovery review. Decide which models survive. | |
| 3 | GoF panel (no Bayes factors - priors not grounded enough to trust marginal-likelihood ratios). Hierarchy: BPIC for cheap screening, PSIS-LOO-CV as primary metric (with Pareto-k diagnostic), WAIC as a confirmatory check. | |
| **3.9** | **STOP & REVIEW (with PI)**: review Pareto-k diagnostics (flag any model with > 10% k > 0.7), check LOO/WAIC agreement, identify candidate winner(s) or co-winners. | |
| 4 | PPC for top model(s): per-subject KS + theory-relevant contrasts on exp1+2. | |
| **4.9** | **STOP & REVIEW**: PPC quality + exp1+2 vs exp3 descriptive comparison (population-shift check). | |
| 5 | OOD test: within-subject prediction. Use trained `$alpha` to simulate exp3 conditions (incl. all-cue: see mechanism below). Compare to empirical exp3. | |
| **5.9** | **STOP & REVIEW (with PI)**: define pass/fail rule (deferred until now), interpret results. | |
| 6 | PPC + OOD for all other accepted models (diagnostic comparison). | |
| 7 | Identifiability spot-check: max pairwise posterior correlation per accepted model. | |
| **7.9** | **STOP & REVIEW**: final synthesis. Joint GoF + OOD ranking, write-up plan. | |
| 8 | Conclude / write up. | |

**Asymmetric convergence target for step 2** (overrides the symmetric defaults in `R/config.R`):

| Block | Rhat | ESS bulk | Notes |
|---|---|---|---|
| `$mu` | < 1.05 | > 500 | Population params reported with CIs; tighter Rhat than EMC2 default. |
| `$alpha` | < 1.1 | > 400 | EMC2-default-aligned; subject-level params feed OOD simulation. |
| `$sigma2` | descriptive only | descriptive only | Not used in prediction under within-subject OOD design. |
| `$correlation` | descriptive only | descriptive only | Routinely non-convergent in hierarchical LBA; report as known limitation. |

This is implemented in `check_block_convergence()` in `helpers/fitting.R`: `stop_criteria` is evaluated only on `$mu` + `$alpha` rows of the Rhat/ESS tables, not the full parameter set.

**All-cue prediction mechanism (step 5)**: exp3 introduces a novel "all-cue" condition (the same visual cue shown at all 4 locations simultaneously). The trained LBA model handles this without retraining: set `CueAtLoc=X` on **all 4 accumulators** rather than one cued and three NONE. The additive linear LBA then predicts (a) uniformly faster RTs, (b) no location bias, (c) linear speedup vs. single-cue. Any of these failing in empirical exp3 is informative falsification (attention-splitting, saturation, or non-additive cue combination).

**Deferred decisions** (do NOT pre-decide; resolve at the listed checkpoint):
- OOD contrast pass/fail rule → resolve at 5.9.
- `$sigma2` non-convergence acceptance for models 4-5 → resolve at 2.9.

**No forced single winner**: GoF and OOD rankings are reported jointly. The analysis may legitimately conclude with co-winners or with different "best" models for different criteria.

**Compute envelope through step 5** (parallel cloud, spot pricing): ~$200-300, ~3-4 weeks wall-clock.

## Important files

- `R/config.R` - all knobs (priors, RNG, paths, cores)
- `R/model_fitting/fit_initial.R` - master batch fit
- `R/model_fitting/fit_extend_local.R` - local batch extend (2 models in parallel if cores allow; `--sequential` flag to override)
- `R/model_fitting/fit_extend_cloud.R` - cloud single-model extend (called by `cloud_setup.sh`)
- `R/model_fitting/helpers/logging.R` - timestamped logging, error reporting, config serialisation (no dependencies)
- `R/model_fitting/helpers/data.R` - CSV loading, RT filtering, EMC2 factor closures; sources `logging.R`
- `R/model_fitting/helpers/build_model.R` - `build_lba_model()` factory; sources `data.R` and `config.R`
- `R/model_fitting/helpers/fitting.R` - `get_core_args`, `save_model`, `check_block_convergence`, `extend_model`, `model_log_path`; sources `build_model.R`. **Single entry point for fit scripts**.
- `R/model_fitting/model1.R` - canonical template for a model variant (thin wrapper; see `build_lba_model()` in `helpers/build_model.R`)
- `R/analysis/compare_models.R` - diagnostics + GoF tables
- `load_data.py` - Python loaders and the EMC2 design-matrix builder
- `enum_types.py` - canonical factor-level orderings
- `__tests__/run_tests.R` - test entry point; gated by `TEST_LEVEL` env var (1/2/3)
- `__tests__/fixtures/sample_data.csv` - committed synthetic design matrix (~240 rows)
- `__tests__/helpers/` - level-1 unit tests (logging, data, model helpers; no EMC2)
- `__tests__/models/` - level-2 build tests (`make_emc()` for all 5 models; requires EMC2)
- `__tests__/fit/` - level-3 smoke tests (tiny MCMC; CI only)
- `.github/workflows/test.yml` - CI: L1 unit tests + L2 build tests (auto on push/PR)
- `.github/workflows/smoke.yml` - CI: L3 smoke tests (manual dispatch only)
- `.github/r-deps-level1.txt` / `r-deps-level2.txt` - package lists used by CI cache keys

## Gotchas

- Running an R script with the wrong cwd silently fails on the first `source("R/config.R")`. Always start from the repo root.
- Per-model failures are caught by `tryCatch` in `fit_initial.R` so the batch keeps going. Treat `emc2_models/fit_initial/log.txt` as authoritative for run status, not stdout.
- `CONSTANTS = c(sv = log(1))` in `config.R` is an **identifiability anchor** for the LBA. Removing or changing it will silently make the model non-identifiable.
- Dependencies are not pinned in any manifest. Python imports observed: `pandas`, `numpy`, `hssm`, `pymc`, `pytensor`, `pylater`, `pyddm`, `matplotlib`. R: `EMC2`, `dplyr`, `readr`, `tools`.
- Avoid the em-dash (-) in any text destined for academic outputs; use `-` or en-dash (–) instead. This is a per-user writing rule.

## Legacy / do not modify

Everything in `__exploratory/` is superseded code kept for reference. Do not edit, import from, or treat as patterns for current work. Subdirectories:

- `__exploratory/__do_not_use/` - old raw-data loaders and ad-hoc notebooks.
- `__exploratory/hssm_models/` - custom-coded HSSM (PyMC) LBA models; superseded by the native LBA implementation in `R::EMC2`.
- `__exploratory/LATER/` - exploratory notebooks (`check_assumptions.ipynb`, `pooled_results.ipynb`).
