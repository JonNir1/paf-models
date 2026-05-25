# paf-models

Bayesian hierarchical modeling of the **Priority Accumulation Framework (PAF)** theory of visual attention. Saccade-latency data from two visual-search experiments (exp1, exp2) are fit with a family of hierarchical Linear Ballistic Accumulator (LBA) models using R + `EMC2`. A third experiment (exp3) is held out for out-of-distribution testing.

---

## Prerequisites

**R** (`EMC2`, `dplyr`, `readr`, `tools`, `testthat`)

```r
install.packages(c("EMC2", "dplyr", "readr", "tools", "testthat"))
```

**Python** (`pandas`, `numpy`) -- only needed to regenerate the design matrix from raw CSVs.

**Data**: `data/` is gitignored. A fresh clone has no data. You need to supply:
- `data/exp1/Exp1_clean.csv`
- `data/exp2/Exp2_clean.csv`

Then regenerate the R-ready design matrix:

```
python playground.py    # writes data/emc2_design_matrix.csv
```

**Working directory**: all scripts must be run from the **repo root**. Never `cd` into a subdirectory first.

---

## Directory structure

```
paf-models/
|
|- load_data.py                  # Python: loads + filters exp1/exp2, builds design matrix
|- enum_types.py                 # Python: canonical factor-level orderings
|- playground.py                 # Python: writes data/emc2_design_matrix.csv
|
|- R/
|   |- config.R                  # Single source of truth: priors, RNG, cutoffs, paths, convergence criteria
|   |- model_fitting/
|   |   |- model1.R .. model5.R  # LBA model variants (differ in v/B/sv formulas)
|   |   |- fit_initial.R         # Phase 1: fit all models for 1000 iterations
|   |   |- fit_extend_local.R    # Phase 2 (local): extend fits in parallel until convergence
|   |   |- fit_extend_cloud.R    # Phase 2 (cloud): single-model extend, syncs to S3/GCS
|   |   |- cloud_setup.sh        # Bootstrap script for cloud VMs (install R, clone repo, run)
|   |   |- examine_model.R       # Interactive: inspect a single fitted model
|   |   |- test_fit_extend.R     # Local smoke test for the extension pipeline
|   |   |- compare_models.R      # Diagnostics + GoF comparison across all models
|   |   |- diagnostics_helpers.R # Helper functions for convergence and fit summaries
|   |   |- helpers/
|   |       |- logging.R         # Timestamped logging, error reporting
|   |       |- data.R            # CSV loading, RT filtering, EMC2 factor closures
|   |       |- build_model.R     # build_lba_model() factory (shared boilerplate for all models)
|   |       |- fitting.R         # get_core_args(), save_model(), check_block_convergence(), extend_model()
|   |- analysis/                 # (empty - scripts moved to model_fitting/)
|
|- __tests__/
|   |- run_tests.R               # Entry point; gated by TEST_LEVEL env var (1/2/3)
|   |- fixtures/
|   |   |- sample_data.csv       # Synthetic design matrix for tests (~240 rows)
|   |- helpers/                  # Level-1 unit tests (logging, data, model helpers; no EMC2)
|   |- models/                   # Level-2 build tests (make_emc() for all 5 models; requires EMC2)
|   |- fit/                      # Level-3 smoke tests (tiny MCMC; slow, manual CI only)
|
|- .github/
|   |- workflows/
|   |   |- test.yml              # CI: L1 + L2 on every push / PR to main (~10-15 min)
|   |   |- smoke.yml             # CI: L3 smoke tests, manual dispatch only
|   |- r-deps-level1.txt         # Package list for L1 cache key
|   |- r-deps-level2.txt         # Package list for L2 cache key
|
|- data/                         # gitignored - must be supplied locally
|- emc2_models/                  # gitignored - fitted .rds files + logs land here
|   |- fit_initial/              #   output of fit_initial.R (1000-sample fits + log.txt)
|   |- fit_extend/               #   output of fit_extend_*.R (extended fits + per-model logs)
|- Results/                      # gitignored - model comparison outputs
|- docs/                         # Meeting slides, articles, model specs (reference only)
|- __exploratory/                # Superseded code kept for reference - do not modify
```

---

## Running the pipeline

```
# Phase 1: initial fit (1000 iterations per model)
Rscript R/model_fitting/fit_initial.R

# Phase 2: extend until convergence (edit model_files list in script first)
Rscript R/model_fitting/fit_extend_local.R              # parallel if cores allow
Rscript R/model_fitting/fit_extend_local.R --sequential # force sequential

# Analysis
source("R/model_fitting/compare_models.R") # GoF comparison across all models
source("R/model_fitting/examine_model.R")  # inspect a single model

# Tests
Rscript __tests__/run_tests.R                    # L1: unit tests (<5 s, no EMC2)
TEST_LEVEL=2 Rscript __tests__/run_tests.R       # L2: + model build tests (~10-15 min)
```

---

## Analysis plan

Steps marked **STOP & REVIEW** are checkpoints requiring human judgment before proceeding. Steps marked *(PI)* require PI sign-off.

| Step | Description | Status |
|------|-------------|--------|
| 0a | Pre-register PAF predictions | DONE |
| 0b | Pre-hoc exclusion: RT cutoffs (0.23-1.0 s) only; no subject filtering | DONE |
| 1 | **Initial fit** -- `fit_initial.R`: 1000 MCMC samples per model | DONE |
| 2 | **Extend fits** -- `fit_extend_local.R`: run until asymmetric convergence criteria are met (`$mu`: Rhat < 1.05, ESS > 500; `$alpha`: Rhat < 1.1, ESS > 400; `$sigma2`/`$correlation` descriptive only) | NEXT |
| 2.4 | *Sanity check*: flag models with severe non-convergence (mu Rhat > 1.1 or ESS < 200) before proceeding | |
| 2.5 | **Parameter recovery** -- 3 simulations per model using post-extend posterior means as ground truth | |
| 2.9 | **STOP & REVIEW *(PI)***: convergence + recovery review; decide which models survive | |
| 3 | **Goodness of fit** -- BPIC (screening), PSIS-LOO-CV (primary), WAIC (confirmatory); no Bayes factors | |
| 3.9 | **STOP & REVIEW *(PI)***: Pareto-k diagnostics, LOO/WAIC agreement, identify candidate winner(s) | |
| 4 | **Posterior predictive checks** -- per-subject KS test + theory-relevant contrasts on exp1+2 | |
| 4.9 | **STOP & REVIEW**: PPC quality + exp1+2 vs exp3 population-shift check | |
| 5 | **Out-of-distribution test** -- use trained subject-level parameters (`$alpha`) to predict exp3, including the novel all-cue condition | |
| 5.9 | **STOP & REVIEW *(PI)***: define pass/fail rule (deferred to this point), interpret OOD results | |
| 6 | PPC + OOD for all other accepted models (diagnostic comparison) | |
| 7 | **Identifiability check** -- max pairwise posterior correlation per accepted model | |
| 7.9 | **STOP & REVIEW**: final synthesis; joint GoF + OOD ranking; write-up plan | |
| 8 | Conclude / write up | |

**All-cue condition (step 5)**: exp3 introduces a novel condition where the spatial cue appears at all 4 locations simultaneously. The trained LBA handles this without retraining -- set `CueAtLoc=X` on all 4 accumulators. The model then predicts uniformly faster RTs, no location bias, and linear speedup vs. single-cue. Failures are informative falsification.

**No forced single winner**: GoF and OOD rankings are reported jointly. The analysis may end with co-winners or different best models per criterion.
