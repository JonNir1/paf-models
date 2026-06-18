# paf-models

Bayesian hierarchical modeling of the **Priority Accumulation Framework (PAF)** theory of visual attention. Saccade-latency data from two visual-search experiments (exp1, exp2) are fit with a family of hierarchical Linear Ballistic Accumulator (LBA) models using R + `EMC2`. A third experiment (exp3) is held out for out-of-distribution testing.

---

## Prerequisites

**R** (`EMC2`, `dplyr`, `readr`, `tools`, `testthat`)

```r
install.packages(c("EMC2", "dplyr", "readr", "tools", "testthat"))
```

**Data**: `data/` is gitignored. A fresh clone has no data. You need to supply:
- `data/exp1/Exp1_clean.csv`
- `data/exp2/Exp2_clean.csv`

**Working directory**: all scripts must be run from the **repo root**. Never `cd` into a subdirectory first.

---

## Directory structure

```
paf-models/
|
|- R/
|   |- config.R                  # Project-level: RNG, RT cutoffs, paths (OUTPUTS_DIR, MODELS_*_DIR, EVAL_DIR)
|   |- utils.R                   # source_root(), parse_int_arg, parse_str_arg, check_valid_string
|   |- helpers/                  # Cross-cutting helpers (used by fit AND eval)
|   |   |- logging.R             # Timestamped logging, error reporting
|   |   |- data.R                # CSV loading, RT filtering, EMC2 factor closures
|   |- fit/
|   |   |- fit_config.R          # Priors, N_CHAINS, fit/convergence/recovery params, CONSTANTS
|   |   |- model1.R .. model5.R  # LBA model variants (differ in v/B/sv formulas)
|   |   |- fit_initial.R         # Phase 1: fit all models for 1000 iterations
|   |   |- fit_extend_local.R    # Phase 2 (local): extend fits in parallel until convergence
|   |   |- fit_extend_cloud.R    # Phase 2 (cloud): single-model extend, syncs to S3/GCS
|   |   |- fit_recovery_cloud.R  # Step 2.5: parameter recovery (one sim per invocation)
|   |   |- fit_ppc_cloud.R        # Step 4: posterior predictive simulation on the cloud
|   |   |- helpers/
|   |       |- build_model.R     # build_lba_model() factory (shared boilerplate for all models)
|   |       |- fitting.R         # get_core_args(), save_model(), check_block_convergence(), extend_model()
|   |       |- recovery.R        # extract_group_params(), extract_design(), simulate_recovery_data()
|   |- eval/
|       |- eval_config.R         # Eval params + RECOVERY_EVAL_DIR (minimal)
|       |- convergence.R         # Convergence table + step-2.9 verdict (outputs convergence.{rds,csv})
|       |- goodness_of_fit.R     # GoF/model comparison (DIC/BPIC; step-3 scaffolding)
|       |- recovery.R            # Load _extended recovery fits; population table, scatter, z/contraction
|       |- ppc.R                 # Step-4 posterior predictive checks (per-subject KS + contrasts)
|       |- review_convergence_and_recovery.R  # Step-2.9 synthesis (convergence verdict + recovery)
|       |- examine_model.R       # Interactive: inspect a single fitted model
|       |- helpers/
|           |- convergence.R    # Rhat/ESS extraction, create_convergence_table(), add_convergence_verdict()
|           |- recovery.R        # Recovery-eval computations (prior-SD, z/contraction, RMSE/r)
|           |- gof.R             # Goodness-of-fit computations (DIC/BPIC/LOO/WAIC)
|           |- ppc.R             # PPC computations (per-subject KS, theory contrasts)
|           |- plot.R            # Plotly figure builders + save_plotly_png()
|           |- io.R             # load_model(), save_eval_table(), newer_than_inputs()
|
|- scripts/
|   |- helpers.sh                # Shared config defaults + cloud copy helpers (sourced by scripts below)
|   |- vm_setup.sh               # One-time R + EMC2 install on a fresh Ubuntu VM
|   |- run_extend.sh             # Download initial .rds, run fit_extend_cloud.R, sync results
|   |- run_recovery.sh           # Download extended .rds, run fit_recovery_cloud.R, sync results
|   |- run_ppc.sh                # Download extended .rds, run fit_ppc_cloud.R, sync results
|
|- __tests__/
|   |- run_tests.R               # Entry point; gated by TEST_LEVEL env var (1/2/3)
|   |- fixtures/
|   |   |- sample_data.csv       # Synthetic fixture matching load_data() output (one row/trial, 15 cols, 120 rows)
|   |- helpers/                  # Level-1 unit tests (logging, data, model helpers; no EMC2)
|   |- models/                   # Level-2 build tests (make_emc() for all 5 models; requires EMC2)
|   |- fit/                      # Level-3 smoke tests (tiny MCMC; slow, manual CI only)
|
|- .github/
|   |- workflows/
|   |   |- test.yml              # CI: L1 unit tests on every push / PR to main (fast)
|   |   |- build.yml             # CI: L2 build tests, nightly (03:00 UTC) + manual dispatch
|   |   |- smoke.yml             # CI: L3 smoke tests, manual dispatch only
|   |- r-deps-level1.txt         # Package list for L1 cache key
|   |- r-deps-level2.txt         # Package list for L2 cache key
|
|- data/                         # gitignored - must be supplied locally
|- outputs/                      # gitignored - everything generated by the pipeline
|   |- models/
|   |   |- fit_initial/          #   output of fit_initial.R (1000-sample fits + log.txt)
|   |   |- fit_extend/           #   output of fit_extend_*.R (extended fits + per-model logs)
|   |   |- fit_recovery/         #   output of fit_recovery_cloud.R (recovery fits + true_alpha)
|   |- evaluation/               #   model comparison + step-2.5 recovery analysis outputs
|- docs/                         # Meeting slides, articles, model specs (reference only)
```

### Archived code

Superseded code lives on the **`archive/legacy-python`** branch (not on `main`), retrievable via
`git checkout archive/legacy-python -- <path>`. It holds the pre-cleanup snapshot of:

- `__exploratory/__do_not_use/` -- old raw-data loaders and ad-hoc notebooks
- `__exploratory/LATER/` -- LATER-model exploratory notebooks
- `__exploratory/hssm_models/` -- custom HSSM (PyMC) LBA models, superseded by `EMC2`
- `enum_types.py`, `load_data.py`, `playground.py` -- the legacy Python data pipeline (replaced by the R-native `load_data()` in `R/helpers/data.R`)

These form one dependency chain rooted at `enum_types.py`, so the branch is internally consistent and runnable as a unit.

---

## Running the pipeline

```
# Phase 1: initial fit (1000 iterations per model)
Rscript R/fit/fit_initial.R

# Phase 2: extend until convergence (edit model_files list in script first)
Rscript R/fit/fit_extend_local.R              # parallel if cores allow
Rscript R/fit/fit_extend_local.R --sequential # force sequential

# Analysis
source("R/eval/convergence.R")                     # convergence table + step-2.9 verdict
source("R/eval/goodness_of_fit.R")                 # GoF/model comparison (DIC/BPIC; step-3 scaffolding)
source("R/eval/recovery.R")                        # step-2.5 recovery analysis (after cloud runs)
source("R/eval/ppc.R")                             # step-4 posterior predictive checks
source("R/eval/review_convergence_and_recovery.R") # step-2.9 synthesis (convergence + recovery)
source("R/eval/examine_model.R")                   # inspect a single model

# Tests (tiered; higher TEST_LEVEL implies lower tiers)
Rscript __tests__/run_tests.R                    # L1: unit tests (<5 s, no EMC2)
TEST_LEVEL=2 Rscript __tests__/run_tests.R       # L2: + model build tests (slow, ~tens of min; requires EMC2)
TEST_LEVEL=3 Rscript __tests__/run_tests.R       # L3: + smoke tests (tiny end-to-end MCMC; CI only)
```

**Tiered testing.** L1 is unit tests of pure helpers (fast per-push gate); L2 is integration tests that build the 5 models + the recovery chain (no MCMC) — each model is built once and reused, but `EMC2::design()` is intrinsically slow (~minutes/model), so L2 runs nightly + on manual dispatch rather than per-push; L3 is three end-to-end smoke tests in `test_fit_smoke.R` (Smoke A: `fit_initial`, Smoke B: `extend_model`, Smoke C: recovery — each at `n_chains=2, iter=5`). When adding a new pipeline, add coverage at all three tiers.

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
| 2.5 | **Parameter recovery** -- Replicating Strickland et al. (2026): extract (μ̂, Σ̂) from each extended fit; draw 3 independent sets of subject parameters via `make_random_effects`; simulate data on the real trial structure; refit from scratch. Evaluate with `recovery()` (RMSE + correlation) and z-scores + contraction | |
| 2.9 | **STOP & REVIEW *(PI)***: convergence + recovery review; decide which models survive | |
| 3 | **Goodness of fit** -- BPIC (screening), DIC (reporting only), PSIS-LOO-CV (primary), WAIC (confirmatory); no Bayes factors | |
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
