# paf-models

Bayesian hierarchical modeling of the **Priority Accumulation Framework (PAF)** theory of visual attention. Saccade-latency data from two visual-search experiments (exp1, exp2) are fit with hierarchical Linear Ballistic Accumulator (LBA) models using R + `EMC2`. A third experiment (exp3) is held out for out-of-distribution testing.

A previous analysis (the `model1`–`model5` LBA family, evaluated through step 4.9) is archived; this `main` is set up for a new analysis with a fresh model family. See [Archived analysis](#archived-analysis).

---

## Prerequisites

**R** (`EMC2`, `dplyr`, `readr`, `tools`, `testthat`)

```r
install.packages(c("EMC2", "dplyr", "readr", "tools", "testthat", "loo"))
```

The pipeline is verified on EMC2 3.5.0 (3.4.1-made fits also work unchanged; never run
`EMC2::update2version()` on them). EMC2 has no LOO/WAIC, hence `loo`.

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
|   |- config.R                  # Project-level: RNG, RT cutoffs, paths (OUTPUTS_DIR, MODELS_FIT_DIR, EVAL_DIR)
|   |- utils.R                   # source_root(), parse_int_arg, parse_str_arg, check_valid_string
|   |- helpers/                  # Cross-cutting helpers (used by fit AND eval)
|   |   |- logging.R             # Timestamped logging, error reporting
|   |   |- data.R                # CSV loading, RT filtering, EMC2 factor closures
|   |- fit/
|   |   |- fit_config.R          # Priors, N_CHAINS, fit-loop defaults, default_convergence_criteria(), CONSTANTS
|   |   |- fit_cloud.R           # Unified single-model runner (build-fresh OR resume); syncs to S3/GCS
|   |   |- fit_recovery_cloud.R  # Parameter recovery (one sim per invocation) via the unified core
|   |   |- fit_ppc_cloud.R        # Posterior predictive simulation on the cloud
|   |   |- fit_bf_cloud.R        # Bridge-sampling marginal likelihood of one fit (cloud; feeds the BF + model-recovery evals)
|   |   |- helpers/
|   |       |- build_model.R     # build_lba_model() factory (shared boilerplate for LBA variants)
|   |       |- fitting.R         # get_core_args(), save_model(), check_convergence(), fit_to_convergence()
|   |       |- recovery.R        # extract_group_params(), extract_design(), simulate_recovery_data()
|   |- eval/
|       |- eval_config.R         # Eval params, discover_model_names(), model_colors(), thresholds
|       |- convergence.R         # Convergence table + verdict (outputs convergence.{rds,csv})
|       |- goodness_of_fit.R     # GoF/model comparison (DIC/BPIC/LOO/WAIC)
|       |- bayes_factors.R       # Marginal likelihoods + log Bayes factors vs a reference model
|       |- model_recovery.R      # Model recovery: generating x selected confusion matrix
|       |- recovery.R            # Load recovery fits; population table, scatter, z/contraction
|       |- ppc.R                 # Posterior predictive checks (per-subject KS + contrasts)
|       |- review_convergence_and_recovery.R  # Convergence + recovery synthesis
|       |- examine_model.R       # Interactive: inspect a single fitted model
|       |- helpers/              # convergence/recovery/gof/bf/model_recovery/ppc computations, plot.R, io.R
|
|- scripts/
|   |- helpers.sh                # Shared config defaults + cloud copy helpers (sourced by scripts below)
|   |- vm_setup.sh               # One-time R + EMC2 install on a fresh Ubuntu VM
|   |- run_fit.sh                # Build-fresh OR resume a fit on a VM via fit_cloud.R, sync results
|   |- run_recovery.sh           # Download a fit, run fit_recovery_cloud.R, sync results
|   |- run_ppc.sh                # Download a fit, run fit_ppc_cloud.R, sync results
|   |- run_bf.sh                 # Download a fit, run fit_bf_cloud.R (bridge-sampling marginal likelihood), sync results
|
|- __tests__/
|   |- run_tests.R               # Entry point; gated by TEST_LEVEL env var (1/2/3)
|   |- fixtures/
|   |   |- sample_data.csv       # Synthetic fixture matching load_data() output (one row/trial, 15 cols, 120 rows)
|   |   |- test_model.R          # Minimal synthetic LBA model used by L2/L3
|   |- helpers/                  # Level-1 unit tests (logging, data, fit/recovery helpers; no EMC2)
|   |- models/                   # Level-2 build + recovery-chain tests on the synthetic model (requires EMC2)
|   |- fit/                      # Level-3 smoke tests (tiny MCMC; slow, weekly + manual CI)
|
|- .github/
|   |- workflows/
|   |   |- test.yml              # CI: L1 unit tests on every push / PR to main (fast) + manual dispatch
|   |   |- build.yml             # CI: L2 build tests, nightly (03:00 UTC) + manual dispatch
|   |   |- smoke.yml             # CI: L3 smoke tests, weekly + manual dispatch
|   |- r-deps-level1.txt         # Package list for L1 cache key
|   |- r-deps-level2.txt         # Package list for L2 cache key
|
|- data/                         # gitignored - must be supplied locally
|- outputs/                      # gitignored - everything generated by the pipeline
|   |- models/
|   |   |- fit/                  #   output of the unified fit pipeline (YYMMDD_<name>.rds + logs)
|   |   |- fit_recovery/         #   output of fit_recovery_cloud.R (recovery fits + true_alpha)
|   |   |- fit_ppc/              #   output of fit_ppc_cloud.R (posterior-predictive draws)
|   |   |- fit_bf/               #   output of fit_bf_cloud.R (per-fit marginal-likelihood files)
|   |- evaluation/               #   convergence / GoF / recovery / PPC outputs
|- docs/                         # Meeting slides, articles, model specs (reference only, gitignored)
```

### Archived code

Superseded code lives on the **`archive/legacy-python`** branch (not on `main`), retrievable via
`git checkout archive/legacy-python -- <path>`. It holds the pre-cleanup snapshot of the legacy
Python data pipeline and exploratory notebooks (one dependency chain rooted at `enum_types.py`).

---

## The model

Define a model as a thin script that returns an EMC2 object from `build_lba_model()` (the shared
factory in `R/fit/helpers/build_model.R`). It only needs to supply what differs between variants -
the `v` and `B` formulas plus any model-specific prior entries - and define `MODEL_NAME` and a
`build_model(data, n_chains)` function, plus `STRUCTURAL_UNIDENTIFIABLE_PATTERN` (a regex for
parameters the design cannot identify, or `NA_character_` if none; read by the recovery eval without executing the script, so it must be a top-level assignment with a self-contained right-hand side, and the script is found by its declared `MODEL_NAME`, so the file may have any name but names must be unique within `R/fit/`). `__tests__/fixtures/test_model.R` is a minimal working
template; the retired `model1`–`model5` definitions on the `analysis1` branch are fuller examples.

- **Formulas and priors.** `v_formula`, `B_formula` and `sv_formula` are required (`A_formula` defaults
  to `A ~ 1`, `t0 ~ 1` is fixed). `fit_config.R` holds only the intercept priors (`v`, `B`, `A`, `t0`);
  the prior of every effect the design samples is passed by the model via `extra_mu`/`extra_sd`, and a
  sampled parameter without a prior is an error. `functions =` selects the factor closures given to
  `design()` (default: all of `StimulusAtLoc`, `TargetAtLoc`, `CueAtLoc`, `PrevTargetAtLoc`,
  `SearchDifficulty`); pass only those the formulas use to shorten `design()`.
- **Per-model data subset.** A script may declare a top-level `MODEL_DATA_ARGS <- list(...)` of extra
  `load_data()` arguments (e.g. `list(difficulties = c("EASY", "DIFFICULT"))`), read without executing
  the script like `STRUCTURAL_UNIDENTIFIABLE_PATTERN`. The data location, RT cutoffs and target-repeat
  rule belong to the project config, so declaring `data_dir`, `min_rt`, `max_rt` or
  `allow_target_repeats` is an error; no declaration means no extra arguments. Every runner
  (`fit_cloud.R`, `fit_recovery_cloud.R`, `fit_ppc_cloud.R`, `R/eval/ppc.R`) loads a model's data through
  `load_model_data(<script>)`.

---

## Running the pipeline

### Fitting

A single function, `fit_to_convergence()` (`R/fit/helpers/fitting.R`), fits any EMC2 object to
convergence. It handles both a freshly-built (unfitted) model (warm-up + sampling) and a
previously-fit one (resume sampling), driven by a `convergence_criteria` list.

```r
# Local, interactive: build a model and fit it to convergence.
source("R/fit/helpers/fitting.R")     # transitively loads build_model + config
source("R/fit/mymodel.R")             # your model: defines build_model() + MODEL_NAME
data <- load_data(min_rt = MIN_SACCADE_CUTOFF, max_rt = MAX_SACCADE_CUTOFF,
                  allow_target_repeats = ALLOW_TARGET_REPEAT)
res <- fit_to_convergence(
  build_model(data, n_chains = N_CHAINS),
  convergence_criteria = default_convergence_criteria(),   # num_samples + per-group Rhat/ESS
  max_tries  = MAX_TRIES,
  batch_size = STEP_SIZE,
  save_path  = file.path(MODELS_FIT_DIR, "260618_mymodel.rds"),
  save_every = 2                                           # checkpoint cadence (NULL = end only)
)
```

`convergence_criteria` is a list: a `num_samples` floor (sample-stage iters per chain) plus a
per-group `list(max_rhat=, min_ess=)` for any of `mu` / `Sigma2` / `alpha` / `correlation`. Groups
you omit are descriptive-only (not gated) - `default_convergence_criteria()` gates `mu` and `alpha`.

```bash
# Cloud (one model per VM; syncs each checkpoint to S3/GCS via run_fit.sh):
./scripts/run_fit.sh --model-script R/fit/mymodel.R     # build fresh + fit to convergence
./scripts/run_fit.sh --resume 260618_mymodel.rds        # resume a saved fit
```

### Simulation (recovery and PPC)

`fit_recovery_cloud.R` and `fit_ppc_cloud.R` truncate their simulated RTs to `SIM_RT_WINDOW`
(`fit_config.R`; `NULL` = untruncated, otherwise `c(min, max)` in seconds, inclusive like
`filter_data()`) and log the dropped fraction overall and per subject. Only the simulated data are
truncated; the likelihood stays the untruncated LBA.

### Bayes factors and model recovery

```bash
./scripts/run_bf.sh 260618_mymodel.rds                  # bridge-sampling log marginal likelihood (MLL) of one fit
./scripts/run_recovery.sh 260618_mymodel.rds 1 --fit-model-script R/fit/other.R   # refit simulated data with another model
```

`R/eval/bayes_factors.R` tabulates each model's MLL (`BF_REPS` repetitions) and its log Bayes factor
against a reference model, with the spread across repetitions. It prefers the MLL files that `run_bf.sh`
wrote to `outputs/models/fit_bf/` and computes locally (slow) only for missing ones. For model recovery,
`--fit-model-script` refits the data simulated from one model with another; the output files are named
`<gen>_recovery_sim<N>_fit_<fitted model>` (same-model files keep `<gen>_recovery_sim<N>`, which is all
`R/eval/recovery.R` reads). `R/eval/model_recovery.R` selects, per generating model and simulation, the
fitted model with the highest MLL and writes the generating x selected confusion matrix and a heatmap.

### Analysis

```r
source("R/eval/convergence.R")                     # convergence table + verdict
source("R/eval/goodness_of_fit.R")                 # GoF/model comparison (DIC/BPIC/LOO/WAIC)
source("R/eval/bayes_factors.R")                   # marginal likelihoods + log Bayes factors (bridge sampling)
source("R/eval/model_recovery.R")                  # model recovery: generating x selected confusion matrix
source("R/eval/recovery.R")                        # parameter-recovery analysis (after cloud runs)
source("R/eval/ppc.R")                             # posterior predictive checks
source("R/eval/review_convergence_and_recovery.R") # convergence + recovery synthesis
source("R/eval/examine_model.R")                   # inspect a single model
```

Eval drivers discover the active model set from `MODELS_FIT_DIR` (`discover_model_names()`) - no
hardcoded model list. The PPC condition cells are the combinations of `PPC_GROUP_VARS`
(`eval_config.R`; default `experiment`, `cue_size`, `search_difficulty`), pre-settable before
sourcing `R/eval/ppc.R`; the figures' x variables are the grouping variables other than `experiment`.

### Tests

```bash
Rscript __tests__/run_tests.R                    # L1: unit tests (<5 s, no EMC2)
TEST_LEVEL=2 Rscript __tests__/run_tests.R       # L2: + build/recovery-chain tests (slow; requires EMC2)
TEST_LEVEL=3 Rscript __tests__/run_tests.R       # L3: + smoke tests (tiny end-to-end MCMC; CI only)
```

**Tiered testing.** L1 (fast per-push gate, no EMC2) covers the pure helpers, `load_data()` end to
end on synthetic raw CSVs, config invariants, and the fit/PPC/recovery orchestration with EMC2
mocked through the `emc_*` wrappers. L2 (real EMC2, no MCMC) builds the synthetic `test_model` once
and runs checks on a committed tiny EMC2 3.5.0 fit (`__tests__/fixtures/test_model_fitted.rds`, plus a
legacy 3.4.1 fit kept to show old fits need no migration): EMC2 object shapes, per-trial
log-likelihood vs EMC2's own, GoF/LOO and recovery-statistic checks, and PPC simulation. Because `EMC2::design()` is
intrinsically slow (~minutes), L2 runs nightly + on manual dispatch rather than per-push. L3
(`test_fit_smoke.R`, weekly + manual dispatch) drives the synthetic model end-to-end with tiny MCMC: Smoke A/B
(`fit_to_convergence` fresh + resume) and Smoke C (recovery). When adding a new pipeline, add the
logic tests at L1 (mocking the `emc_*` seam) and real-EMC2 coverage at L2 or L3.

---

## Analysis plan

> **Skeleton for the new analysis.** The model family and step-by-step plan are TBD pending the new
> model specifications. Steps marked **STOP & REVIEW** are checkpoints requiring human judgment;
> *(PI)* marks PI sign-off. Fill in as the analysis is designed.

| Step | Description | Status |
|------|-------------|--------|
| 0 | Pre-register predictions; define pre-hoc exclusions (RT cutoffs 0.23-1.0 s) | |
| 1 | **Fit** each model to convergence via `fit_to_convergence()` (`$mu`: Rhat < 1.05, ESS > 500; `$alpha`: Rhat < 1.1, ESS > 400; `$sigma2`/`$correlation` descriptive) | |
| 1.9 | *Sanity check*: flag severe non-convergence before proceeding | |
| 2 | **Parameter recovery** -- extract (μ̂, Σ̂); simulate on the real trial structure; refit; evaluate (RMSE + correlation, z-scores + contraction) | |
| 2.9 | **STOP & REVIEW *(PI)***: convergence + recovery review; decide which models survive | |
| 3 | **Goodness of fit** -- BPIC (screening), DIC (reporting only), PSIS-LOO-CV (primary), WAIC (confirmatory); Bayes factors (bridge sampling) where the model comparison calls for them | |
| 3.9 | **STOP & REVIEW *(PI)***: Pareto-k diagnostics, LOO/WAIC agreement, candidate winner(s) | |
| 4 | **Posterior predictive checks** -- per-subject KS + theory-relevant contrasts on exp1+2 | |
| 4.9 | **STOP & REVIEW**: PPC quality + exp1+2 vs exp3 population-shift check | |
| 5 | **Out-of-distribution test** -- predict exp3 from trained `$alpha` | |
| 5.9 | **STOP & REVIEW *(PI)***: define pass/fail rule, interpret OOD results | |
| ... | final synthesis; write-up | |

**No forced single winner**: GoF and OOD rankings are reported jointly. The analysis may end with
co-winners or different best models per criterion.

---

## Archived analysis

The completed `model1`–`model5` LBA analysis (through step 4.9: convergence, parameter recovery,
goodness-of-fit, and posterior predictive checks) is preserved:

- **Branch `analysis1`** - a complete, runnable snapshot (its own CI guards the old models). Revert with `git checkout analysis1`.
- **Tag `analysis1-v1.0`** - an immutable marker of that state.

It includes the old two-phase fitting pipeline (`fit_initial.R` + `fit_extend_{local,cloud}.R`,
superseded here by `fit_to_convergence()`), the five model definitions, and their model-specific
build/smoke tests.

The current `main` has a CI-verified baseline tag **`unified-pipeline-v1.0`** - the first state with
the unified pipeline passing all tiers (L1 unit, L2 build + recovery chain, L3 smoke A/B/C/D) on real
EMC2. Revert/branch from it with `git switch -c <name> unified-pipeline-v1.0`.
