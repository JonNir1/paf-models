# Changelog

Significant changes between repo versions. Version `v1.0` is the tag `unified-pipeline-v1.0`.

## v1.2 (2026-11-24)

`main` is now analysis-agnostic: the model1-5 leftovers are gone and the generic pieces a new analysis needs are added.

### Breaking changes

- `fit_config.R` keeps only the intercept priors (`v`, `B`, `A`, `t0`) and `CONSTANTS`. The model1-5 effect constants (and the unused `V_SEARCH_*`, `B_SEARCH_*`) are removed: a model passes every effect prior via `extra_mu`/`extra_sd`, and a sampled parameter without a prior is an error.
- `build_lba_model()`: `sv_formula` is required (no `sv ~ StimulusAtLoc` default); new `functions` argument selects the factor closures given to `design()` (default: all five).
- The PPC CLI (`fit_ppc_cloud.R`) needs the model's script in `R/fit/` (found by its declared `MODEL_NAME`), to load the model's data. `run_ppc_simulation()` takes `template_data` and is unchanged in that respect.
- `get_mll()` no longer computes bridge sampling locally unless `ALLOW_LOCAL_MLL <- TRUE` (default `FALSE`); a missing MLL is an error pointing to `scripts/run_bf.sh`. `read_mll()` gained a `reps` argument.

### Model definition and data

- A model script may declare `MODEL_DATA_ARGS <- list(...)`: extra `load_data()` arguments (e.g. `difficulties`), read without executing the script. Data location, RT cutoffs and target-repeat rule stay project config and cannot be declared. All runners and `R/eval/ppc.R` load a model's data through `load_model_data()`.
- Analysis-specific wording removed from the `data.R` docs (the `difficulties` filter, `TargetAtLoc` and `droplevels` stay as generic encoding).

### Simulation

- Recovery and PPC simulations can truncate simulated RTs to `SIM_RT_WINDOW` (`fit_config.R`, default `NULL` = untruncated; inclusive, like `filter_data()`), logging the dropped fraction overall and per subject. The likelihood is unchanged.

### Evaluation

- Bayes factors: `R/eval/bayes_factors.R` (bridge sampling, `BF_REPS` repetitions, log BF against a reference model with the spread across repetitions, cached), fed by per-fit MLL files from the new cloud runner `R/fit/fit_bf_cloud.R` / `scripts/run_bf.sh`. `compare()` and the DIC/BPIC/LOO tables are unchanged.
- Model recovery: `fit_recovery_cloud.R --fit-model-script <path>` refits simulated data with another model (outputs named `<gen>_recovery_sim<N>_fit_<model>`; same-model fit and true-alpha names and `R/eval/recovery.R` are unchanged; the recovery log is now `log_<name>.txt`, e.g. `log_mymodel_recovery_sim1.txt`); `R/eval/model_recovery.R` builds the generating x selected (max marginal likelihood) confusion matrix and heatmap.
- MLL records carry a content fingerprint (`fit_md5`), the repetitions and `n_split_warnings` (EMC2's "split estimates off by 1 log point" warning, counted and muffled); a record is reused only if the fit file name AND md5 match and it holds at least `BF_REPS` repetitions. `n_split_warnings` is a column of the Bayes-factor and model-recovery MLL tables. Local bridge sampling sets `RNGkind(RNG_KIND)` like the cloud runner.
- Model recovery: `select_by_mll()` also returns `margin` (best minus runner-up median MLL) and `spread` (larger repetition range of the two) so near-ties are visible; the candidates of a generating x sim group must share identical `true_alpha` files (saved with a `provenance` attribute: source fit, sim seed, `rt_window`, template-data fingerprint), checked by `recovery_group_problem()`, else the group is a fatal problem (skipped with a warning listing it under `ALLOW_PARTIAL_MODEL_RECOVERY`). `get_mll()` errors name the cause (`mll_status()`). `BF_REPS` is pre-settable. `R/eval/recovery.R` builds its file names with `recovery_stem()`; `N_SIMS` is pre-settable there too.
- PPC condition cells follow `PPC_GROUP_VARS` (default `experiment`, `cue_size`, `search_difficulty`) instead of hard-coded `cue_size` keys. Bug fix: the observed-RT line of `plot_ppc_cdf` is now grouped by every grouping variable (before, `ppc_cdf_difficulty.png` pooled the observed line over cue sizes), so that figure changes. The PPC `.rds` carries an `rt_window` attribute (NA = untruncated). `log_truncation()` reports 0 of 0 instead of NaN% when nothing was simulated.

### Docs and tests

- Removed model1 examples and the analysis1-only CLAUDE.md items (they remain on the `analysis1` branch).
- Fixture model passes its effect priors explicitly with the values the committed fitted fixtures were made with (no fixture regeneration). Analysis1-shaped test data made fixture-relative.

## v1.1 (2026-11-16)

### EMC2

- Pipeline moved from EMC2 3.4.1 to 3.5.0 (newest CRAN release). Fits made under 3.4.1 work unchanged; never run `update2version()` on them.
- The EMC2 version is logged on every run and stamped on saved fits (`emc2_version`, `emc2_version_history`).

### Model definition

- Each model script must declare `STRUCTURAL_UNIDENTIFIABLE_PATTERN` (a regex, or `NA_character_` for none). This replaces the single global pattern.
- Model scripts are located by their declared `MODEL_NAME`, not by file name.

### Evaluation

- DIC/BPIC table reports both EMC2 comparison types (`_conditional` and `_joint` columns). Values differ from v1.0 because EMC2 3.4.1 had a bug in its DIC computation.
- LOO now accounts for autocorrelated draws (`r_eff`). The model comparison requires identical subjects and trial counts across models.
- Recovery eval adds EMC2's own statistics (`recovery_emc2_stats`: Pearson, Spearman, RMSE, coverage) and a `coverage95` column.
- Bayes factor option removed.
- Eval caches are invalidated by changes to model files, thresholds and package versions, not only by file time.

### Fail loudly instead of silently

- Non-finite Rhat/ESS never passes the convergence gate.
- CLIs exit with status 1 on error.
- A malformed or missing `--resume` file is an error (previously the model was silently refit from scratch).
- Ambiguous fit files (same date), missing recovery pairs and missing PPC files are errors. Partial runs need `ALLOW_PARTIAL_RECOVERY` / `ALLOW_PARTIAL_PPC`.
- Subjects and parameters are matched by name, not by position.

### Fixes

- `fit_cloud.R` no longer crashes while logging the fit configuration.
- `PAF_REPO_ROOT` is honoured for code paths, so scripts can run from a directory other than the repo root.
- PPC helpers handle unused factor levels in simulated data.
- `PPC_AD_ALPHA` renamed to `PPC_KS_ALPHA` (the test is Kolmogorov-Smirnov).

### Tests

- Suite restructured into three tiers: L1 (no EMC2, every push), L2 (real EMC2 on a committed fitted fixture, nightly), L3 (MCMC smoke tests, weekly).
- EMC2 is reached only through the `emc_*` wrappers, so L1 can mock it.
- Fitted fixture regenerated under EMC2 3.5.0; the 3.4.1 fixture is kept to test legacy fits.

## v1.0 (`unified-pipeline-v1.0`)

- Baseline: unified fit pipeline (`fit_to_convergence`, `fit_cloud.R`), R-native data loading, CI green on all tiers.

- Eval drivers are reusable on a model subset: every driver honours a pre-set `MODEL_NAMES` (validated by `check_model_names()`), `discover_model_names()` takes a pre-settable `MODEL_EXCLUDE_PATTERN`, and `BF_DIR`, `GOF_DIR` and `LOO_DIR` are pre-settable output dirs (the cache follows), so a separate comparison does not overwrite the main tables.
- The PPC figure functions default `x_var` (and `plot_ppc_cdf`'s `x_facet`) to `ppc_x_var()`, the first non-`experiment` entry of `PPC_GROUP_VARS` (unchanged output for the default `cue_size`); `.latest_ppc()` escapes the model name in its regex.
