# Changelog

Significant changes between repo versions. Version `v1.0` is the tag `unified-pipeline-v1.0`.

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
