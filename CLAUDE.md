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
Rscript __tests__/run_tests.R                    # level 1: helpers unit tests (<5 s, no EMC2)
TEST_LEVEL=2 Rscript __tests__/run_tests.R       # level 2: + model build tests (requires EMC2)
TEST_LEVEL=3 Rscript __tests__/run_tests.R       # level 3: + fit smoke tests (CI only, hours)
```

**Tiered testing strategy.** The suite is tiered by cost and intent; a higher TEST_LEVEL always runs the lower tiers too.

| Tier | Dir | Scope | Cost | When |
|---|---|---|---|---|
| L1 | `__tests__/helpers/` | Unit tests for pure helpers (logging, data, fitting helpers incl. `fit_to_convergence()` validation, recovery helpers). No EMC2 required. | <5 s total | Every push/PR (CI auto). |
| L2 | `__tests__/models/` | Integration tests: builds the synthetic `test_model` (`__tests__/fixtures/test_model.R`) **once** and guards `build_lba_model()`/`make_emc()` + the recovery extract→simulate→build chain. Committed fixture; no MCMC. Build is dominated by `EMC2::design()` (~minutes). | ~tens of min | Nightly + manual dispatch (CI). |
| L3 | `__tests__/fit/` | End-to-end smoke tests with tiny MCMC (n_chains=2), all driven by the synthetic model. One file (`test_fit_smoke.R`): **Smoke A/B** = `fit_to_convergence` (fresh + resume), **Smoke C** = recovery, **Smoke D** = PPC. | minutes-hours | Manual dispatch only (CI). |

CI (GitHub Actions):
- L1 runs automatically on every push and on PRs to `main` (`.github/workflows/test.yml`).
- L2 is **not** per-push (intrinsically slow: `EMC2::design()` is ~minutes per model). It runs nightly (03:00 UTC) and on manual dispatch: Actions tab → "Build Tests" → "Run workflow" (`.github/workflows/build.yml`).
- L3 is manual-only: Actions tab → "Smoke Tests" → "Run workflow" (`.github/workflows/smoke.yml`).
- `use-public-rspm: true` serves pre-compiled Linux binaries; EMC2 installs in ~2 min instead of compiling from source.
- Package caches are keyed on `.github/r-deps-level1.txt` / `r-deps-level2.txt` and auto-invalidate when the dep list changes.

When adding a new pipeline, add a unit test at L1 (for any pure helper), a build/structural test at L2 (uses the fixture, no MCMC), and a smoke test at L3 (tiny MCMC end-to-end).

## Data loading (R-native pipeline)

The pipeline reads raw experiment CSVs directly in R:

1. `R/helpers/data.R` `load_data()` reads `data/exp{1,2}/Exp{1,2}_clean.csv`, applies all column transforms (renaming, distractor-string construction, RT conversion, boolean mapping, cue-size encoding), enforces ordered factors (`search_difficulty` ∈ {EASY < MIXED < DIFFICULT}, `cue_size` ∈ {NONE < SMALL < MEDIUM < LARGE}), and applies RT cutoffs -- returning the same 15-column tibble as before.

`data/` is **gitignored** (see `.gitignore:2`). A fresh clone has no data; the raw cleaned CSVs must be supplied locally.

The earlier Python data pipeline (`load_data.py`, `enum_types.py`, `playground.py`) and its `data/emc2_design_matrix.csv` intermediate were retired and removed from `main`; they live on the `archive/legacy-python` branch (see **Archived code** below).

## Architecture

- **`R/` layout**: split into three layers.
  - `R/config.R` — project-level: RNG (`seed = 42`, `L'Ecuyer-CMRG`), saccade RT cutoffs (0.23 to 1.0 s), the asymmetric convergence thresholds (`MAX_RHAT_MU`/`MIN_ESS_MU` + `MAX_RHAT_ALPHA`/`MIN_ESS_ALPHA`; used by BOTH the fit and eval layers), and output dir paths (`OUTPUTS_DIR`, `MODELS_DIR`, `EVAL_DIR`, `MODELS_FIT_DIR`, `MODELS_RECOVERY_DIR`). Sourced (directly or transitively) by every script.
  - `R/utils.R` — `source_root(rel)`, `parse_int_arg`, `parse_str_arg`, `check_valid_string`. Sourced as the FIRST line of every R file via `source(file.path(Sys.getenv("PAF_REPO_ROOT", getwd()), "R", "utils.R"))`.
  - `R/fit/` — fitting code (`fit_cloud.R`, `fit_recovery_cloud.R`, `fit_ppc_cloud.R`) + `R/fit/fit_config.R` (priors, `N_CHAINS = 3`, fit-loop defaults `MAX_TRIES=20`/`STEP_SIZE=200`/`SAVE_EVERY=2`/`EXTENDED_FIT_SAMPLES=3000`, the `default_convergence_criteria()` builder, recovery params, and the `CONSTANTS = c(sv = log(1))` identifiability anchor). The asymmetric convergence thresholds live in `R/config.R` (shared with eval). Model definitions are NOT on `main` (the model1-5 family is archived on the `analysis1` branch); add a new model as a thin script defining `build_model()`/`MODEL_NAME` (see `__tests__/fixtures/test_model.R`).
  - `R/eval/` — evaluation code: `convergence.R` (convergence table + verdict), `goodness_of_fit.R` (GoF/DIC/BPIC/LOO/WAIC), `recovery.R` (parameter-recovery analysis), `ppc.R` (posterior predictive checks), `review_convergence_and_recovery.R` (convergence+recovery synthesis), `examine_model.R` (interactive) + `R/eval/eval_config.R` (incl. `discover_model_names()` and `model_colors()`).
  - `R/helpers/` — cross-cutting helpers used by both fit and eval: `logging.R`, `data.R`.
  - `R/fit/helpers/` — fit-only helpers: `build_model.R`, `fitting.R`, `recovery.R`.
  - `R/eval/helpers/` — eval-only helpers: `convergence.R` (Rhat/ESS extraction + verdict), `recovery.R` (recovery-eval computations), `gof.R` (GoF computations), `ppc.R` (PPC computations), `plot.R` (Plotly figures), `io.R` (`load_model`, `save_eval_table`, `newer_than_inputs`).
  - Parallelism (`cores_for_chains`, `cores_per_chain`) is auto-detected at runtime by `get_core_args()` in `R/fit/helpers/fitting.R` — no manual core config is needed.
- **Output locations** (from `R/config.R`):
  - `MODELS_FIT_DIR      = "outputs/models/fit"`          — `.rds` files from the unified fit pipeline (`fit_cloud.R` / `fit_to_convergence`), named `YYMMDD_<MODEL_NAME>.rds`, + per-model logs `log_fit_<name>.txt`.
  - `MODELS_RECOVERY_DIR = "outputs/models/fit_recovery"` — `.rds` files from `fit_recovery_cloud.R`.
  - `EVAL_DIR            = "outputs/evaluation"`          — eval outputs (`convergence.{rds,csv}`, GoF tables, recovery analysis under `parameter_recovery/`, PPC under `ppc/`).
  - `LOG_FILE` is **not** in `config.R`; each fit derives its log via `model_log_path()` (e.g. `outputs/models/fit/log_fit_<name>.txt`).
- **Defining a model**: a model is a thin script defining `MODEL_NAME` and `build_model(data, n_chains)`, which delegates to `build_lba_model()` in `R/fit/helpers/build_model.R`. `build_lba_model()` owns all shared boilerplate (base priors, `design()`, `prior()`, `make_emc()`); each model passes only its `v_formula`, `B_formula`, and any extra prior entries. `__tests__/fixtures/test_model.R` is a minimal template; the archived `model1`–`model5` (branch `analysis1`) are fuller examples.
- **Unified fitting** — `fit_to_convergence(emc, convergence_criteria, max_tries, batch_size, save_every=NULL, post_save_hook=NULL, save_path=NULL, ...)` in `R/fit/helpers/fitting.R` is the single entry point (replaces the retired `fit_initial` + `fit_extend_*`):
  - Takes an EMC2 object (not a path). A **fresh** (unfitted) model is warmed up via `EMC2::fit()` (preburn→burn→adapt→initial sample batch); a **pre-fitted** model skips straight to the extension loop. Detection is by the sample-stage iteration count (`.sample_iters()`).
  - The loop adds `batch_size` sampling iters per try (via `run_emc(stage="sample")`) until `convergence_criteria` is met or `max_tries` is exhausted. Convergence = every gated group meets its Rhat/ESS thresholds AND the sample-stage count reaches `num_samples`.
  - `convergence_criteria` is a list: `num_samples` (sample-stage floor) + per-group `list(max_rhat=, min_ess=)` for any of `mu`/`Sigma2`/`alpha`/`correlation`. **Omitted groups are descriptive-only (not gated)** — `default_convergence_criteria()` gates `mu`+`alpha`. Generic check via `check_convergence()`.
  - `save_path`/`save_every` control checkpointing; `post_save_hook(rds_path, log_path)` runs after each save (cloud S3/GCS sync). Inputs are validated up front (`.validate_convergence_criteria()`, `.validate_fit_args()`): reachability (`existing + batch_size*max_tries >= num_samples`), `1 <= save_every <= max_tries`, etc.
  - `fit_cloud.R` is the thin single-model runner (build-fresh via `--model-script` OR `--resume <rds>`) that supplies the cloud hook; `scripts/run_fit.sh` wraps it on a VM.
- **Factor level orderings**: `R/helpers/data.R` is the single source of truth for the canonical level orderings, encoded through closure functions (`StimulusAtLoc`, `CueAtLoc`, `PrevTargetAtLoc`, `SearchDifficulty`) that EMC2's `design()` calls. (The original Python `enum_types.py` definitions are preserved on the `archive/legacy-python` branch but are no longer authoritative.)
- **Latest-version lookup**: `R/eval/helpers/io.R` `load_model()` parses the `YYMMDD_` prefix and always returns the most recent `.rds` for a given model name.

## Analysis workflow

The new analysis (new model family) is being set up; the step-by-step plan is a **skeleton** in `README.md` ("Analysis plan") pending the new model specs. Steps marked `X.9` are **stop-and-review checkpoints**: surface diagnostics and prompt a discussion (PI where noted) rather than auto-proceeding. Do not pre-decide outcomes at these checkpoints.

The **completed** `model1`–`model5` analysis (through step 4.9: convergence, recovery, GoF, PPC) is archived on branch `analysis1` (tag `analysis1-v1.0`); consult it for the prior 16-step plan and findings.

**Asymmetric convergence target** (production default, encoded in `default_convergence_criteria()` reading `R/config.R`):

| Block | Rhat | ESS bulk | Notes |
|---|---|---|---|
| `$mu` | < 1.05 | > 500 | Population params reported with CIs; tighter Rhat than EMC2 default. |
| `$alpha` | < 1.1 | > 400 | EMC2-default-aligned; subject-level params feed OOD simulation. |
| `$sigma2` | descriptive only | descriptive only | Omitted from `convergence_criteria` => not gated; report descriptively. |
| `$correlation` | descriptive only | descriptive only | Routinely non-convergent in hierarchical LBA; report as known limitation. |

`fit_to_convergence()` gates only the groups present in `convergence_criteria`, evaluated by `check_convergence()` in `R/fit/helpers/fitting.R`.

**All-cue prediction mechanism (held-out exp3)**: exp3 introduces a novel "all-cue" condition (the same visual cue shown at all 4 locations simultaneously). A trained LBA handles this without retraining: set `CueAtLoc=X` on **all 4 accumulators** rather than one cued and three NONE. The additive linear LBA then predicts (a) uniformly faster RTs, (b) no location bias, (c) linear speedup vs. single-cue. Any of these failing in empirical exp3 is informative falsification.

**No forced single winner**: GoF and OOD rankings are reported jointly. The analysis may legitimately conclude with co-winners or with different "best" models for different criteria.

## Important files

Project-level:
- `R/config.R` - RNG, RT cutoffs, paths (`OUTPUTS_DIR`, `MODELS_*_DIR`, `EVAL_DIR`, `DATA_DIR`)
- `R/utils.R` - `source_root()` plus `parse_int_arg`, `parse_str_arg`, `check_valid_string`
- `R/helpers/logging.R` - timestamped logging, error reporting, config serialisation
- `R/helpers/data.R` - **entry point `load_data()`** reads raw CSVs end-to-end; `filter_data()` for custom RT cutoffs on an already-loaded tibble; EMC2 factor closures (`StimulusAtLoc`, `CueAtLoc`, `PrevTargetAtLoc`, `SearchDifficulty`); sources `logging.R`

Fitting (`R/fit/`):
- `R/fit/fit_config.R` - priors, `N_CHAINS`, fit-loop defaults, `default_convergence_criteria()`, recovery params, `CONSTANTS` (asymmetric convergence thresholds in `R/config.R`)
- `R/fit/fit_cloud.R` - unified single-model runner: build-fresh (`--model-script`) OR resume (`--resume <rds>`); supplies the S3/GCS cloud hook (called by `scripts/run_fit.sh`)
- `R/fit/fit_recovery_cloud.R` - cloud single-sim parameter recovery via `fit_to_convergence()` (called by `scripts/run_recovery.sh`)
- `R/fit/fit_ppc_cloud.R` - cloud posterior predictive simulation (called by `scripts/run_ppc.sh`)
- `R/fit/helpers/build_model.R` - `build_lba_model()` factory; sources `fit_config.R` and `R/helpers/data.R`
- `R/fit/helpers/fitting.R` - `get_core_args`, `save_model`, `check_convergence`, **`fit_to_convergence`** (single fit entry point), `model_log_path`, validators; sources `build_model.R`.
- `R/fit/helpers/recovery.R` - `extract_group_params`, `extract_design`, `simulate_recovery_data`; sources `fitting.R`.
- New model definitions live alongside these as thin scripts; none are committed on `main` yet (see `__tests__/fixtures/test_model.R` for the template).

Evaluation (`R/eval/`):
- `R/eval/eval_config.R` - eval params, `RECOVERY_EVAL_DIR`, `discover_model_names()` (active set), `model_colors()`, GoF/PPC thresholds
- `R/eval/convergence.R` - convergence table + verdict over discovered models (writes `convergence.{rds,csv}`)
- `R/eval/goodness_of_fit.R` - GoF/model comparison (DIC/BPIC/LOO/WAIC)
- `R/eval/recovery.R` - load recovery fits, produce population table + subject scatter + z-score/contraction plots
- `R/eval/ppc.R` - posterior predictive checks (per-subject KS + theory contrasts)
- `R/eval/review_convergence_and_recovery.R` - convergence + recovery synthesis
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
- `scripts/run_fit.sh` - build-fresh OR resume a fit on a VM via `fit_cloud.R`, sync results
- `scripts/run_recovery.sh` - download a fit, run `fit_recovery_cloud.R`, sync results
- `scripts/run_ppc.sh` - download a fit, run `fit_ppc_cloud.R`, sync results
- `__tests__/run_tests.R` - test entry point; gated by `TEST_LEVEL` env var (1/2/3)
- `__tests__/fixtures/sample_data.csv` - committed synthetic fixture matching `load_data()`'s output contract (one row per trial, 15 columns, 120 rows); regenerate with `generate_fixture.R`
- `__tests__/fixtures/test_model.R` - minimal synthetic LBA model (`build_model()` + `MODEL_NAME`) exercised by L2/L3
- `__tests__/helpers/` - L1 unit tests (logging, data, fit/recovery helpers incl. `fit_to_convergence` validation; no EMC2)
- `__tests__/models/` - L2 build + recovery-chain tests on the synthetic model (requires EMC2)
- `__tests__/fit/test_fit_smoke.R` - L3 smoke tests on the synthetic model: Smoke A/B (`fit_to_convergence` fresh + resume), Smoke C (recovery), Smoke D (PPC). CI manual dispatch only. Bounded `stop_criteria` (`max_gd=Inf`) makes all EMC2 phases exit after a fixed iteration count.
- `.github/workflows/test.yml` - CI: L1 unit tests (auto on push/PR to `main`)
- `.github/workflows/build.yml` - CI: L2 build tests (nightly 03:00 UTC + manual dispatch)
- `.github/workflows/smoke.yml` - CI: L3 smoke tests (manual dispatch only)
- `.github/r-deps-level1.txt` / `r-deps-level2.txt` - package lists used by CI cache keys

## Gotchas

- Running an R script with the wrong cwd silently fails on the first `source("R/config.R")`. Always start from the repo root.
- `fit_cloud.R` wraps the fit in `tryCatch`; treat the per-model log (`outputs/models/fit/log_fit_<name>.txt`) as authoritative for run status, not stdout. `fit_to_convergence()` validates its arguments up front (criteria shape, `save_every` bounds, reachability) so misconfigs fail in milliseconds, not hours in.
- `CONSTANTS = c(sv = log(1))` in `R/fit/fit_config.R` is an **identifiability anchor** for the LBA. Removing or changing it will silently make the model non-identifiable.
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

### `EMC2::design()` is intrinsically slow (L2 runs nightly, not per-push)

`EMC2::design()` is ~minutes per model with the PAF LBA spec, on both synthetic and real data. It is dominated by EMC2 evaluating the custom design `functions` (the `SearchDifficulty`/`StimulusAtLoc`/`CueAtLoc`/`PrevTargetAtLoc` closures) over its design grid; it is **not** row-count-driven (a tiny fixture is just as slow). Real fits absorb this one-time cost inside multi-hour MCMC runs. Consequences for testing:
- L2 builds the synthetic model **once** and reuses it across all its assertions (`test_recovery_build.R`).
- L2 is **off the per-push gate**, on nightly + manual dispatch (`.github/workflows/build.yml`); L1 is the fast per-push gate.

**Deferred (not now):** optimizing `design()` itself (e.g. vectorizing the `SearchDifficulty` closure). This touches the modeling code used by real fits, so it needs careful behavior-preserving validation.

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
