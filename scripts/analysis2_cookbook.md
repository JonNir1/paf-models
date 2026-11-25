# Analysis 2 cookbook (PrevTarget locus)

Commands for each step of the analysis-2 plan (`README.md`, "Analysis plan"). **PowerShell** blocks run
on your PC, **bash** blocks run on an EC2 instance. Launching and terminating instances is manual and is
not repeated here: use `scripts/aws_cookbook.md` sections 1 and 3 (choose spot or on-demand per launch).

Conventions used below:

- `<DATE>` is the `YYMMDD` prefix of a file written by an earlier step (check the bucket listing).
- Models: `pt_null pt_v pt_A pt_B pt_vA pt_vB pt_AB pt_vAB`.
- Bucket root: `s3://jon-nir/paf-models/` (`BUCKET=jon-nir/paf-models` for the scripts).
- Cores are auto-detected per process, so run **one job at a time per instance** (loops below are
  sequential); spread work over several instances for parallelism.
- Later PowerShell blocks assume the session of "Local R session" below (cwd = main checkout,
  `$env:R_LIBS_USER` set); bash blocks assume `cd /opt/paf-models` (see "Instance setup").
- Several fit dates can coexist per model (reruns, resumes). Wherever a step must act on "the" fit of a
  model, the snippets pick the LATEST `YYMMDD_` file per model (names sort chronologically): in bash,
  `sort | awk '{ f[substr($0, 8)] = $0 } END { for (k in f) print f[k] }'` keeps the last name per
  model (everything after the 7-character date prefix).

---

## One-time setup

### Push the code (PowerShell, main checkout)

The instances clone from GitHub, so `main`, the `v1.2` tag and `analysis2` must be on `origin`:

```powershell
cd C:\Users\nirjo\Documents\University\PhD\Projects\paf-models
git push origin main
git push origin v1.2
git push -u origin analysis2
```

### Upload the raw data (PowerShell, only if not already in the bucket)

```powershell
aws s3 ls s3://jon-nir/paf-models/inputs/data/ --recursive
aws s3 cp data\exp1\Exp1_clean.csv s3://jon-nir/paf-models/inputs/data/exp1/Exp1_clean.csv
aws s3 cp data\exp2\Exp2_clean.csv s3://jon-nir/paf-models/inputs/data/exp2/Exp2_clean.csv
```

### Local R session for the eval steps (PowerShell)

Data and outputs live in the main checkout, so switch it to `analysis2` there. This only works while no
other worktree has `analysis2` checked out (check with `git worktree list`; release it there first):

```powershell
cd C:\Users\nirjo\Documents\University\PhD\Projects\paf-models
git switch analysis2
$env:R_LIBS_USER = "C:\Users\nirjo\R_library\4.5"
```

### Instance setup (bash, once per new instance)

```bash
BUCKET=jon-nir/paf-models
sudo git clone https://github.com/JonNir1/paf-models.git /opt/paf-models
sudo chown -R "$USER":"$USER" /opt/paf-models
cd /opt/paf-models
git switch analysis2
./scripts/vm_setup.sh   # R + EMC2, ~5 min
```

Start every bash job below with `cd /opt/paf-models && git pull` and monitor with `tail -f ~/<log>`.

---

## Step 0: prior predictive check (local)

Builds each model once (cached under `outputs/evaluation/prior_predictive/builds/`, several minutes per
model), simulates `PP_N_DRAWS` prior draws on the real trial structure, and writes the table, per-model
summary and `prior_predictive.png` under `outputs/evaluation/prior_predictive/`.

```powershell
Rscript -e "PP_N_DRAWS <- 50L; source('R/eval/prior_predictive.R')"
```

Subset of models:

```powershell
Rscript -e "PP_MODEL_NAMES <- c('pt_null', 'pt_vAB'); source('R/eval/prior_predictive.R')"
```

**0.9 STOP:** confirm the prior table (local findings note, F7) before fitting.

---

## Step 1: fit the 8 models (cloud)

One model per instance (bash):

```bash
MODEL=pt_null   # one of the 8
nohup env BUCKET=jon-nir/paf-models CLOUD=aws \
  ./scripts/run_fit.sh --model-script R/fit/$MODEL.R > ~/fit_$MODEL.log 2>&1 &
```

Or several models sequentially on one instance:

```bash
nohup bash -c 'for m in pt_null pt_v pt_A pt_B; do
  env BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/run_fit.sh --model-script R/fit/$m.R
done' > ~/fit_batch.log 2>&1 &
```

If a fit stops before converging, promote it to `inputs/fit/` (PowerShell) and resume it (bash):

```powershell
aws s3 cp s3://jon-nir/paf-models/results/fit/<DATE>_pt_v.rds s3://jon-nir/paf-models/inputs/fit/<DATE>_pt_v.rds
```

```bash
nohup env BUCKET=jon-nir/paf-models CLOUD=aws \
  ./scripts/run_fit.sh --resume <DATE>_pt_v.rds > ~/resume_pt_v.log 2>&1 &
```

Download the fits and check convergence (PowerShell):

```powershell
aws s3 sync s3://jon-nir/paf-models/results/fit/ outputs\models\fit\ --exclude "*" --include "*pt_*"
Rscript -e "source('R/eval/convergence.R')"
```

**1.9 STOP:** flag severe non-convergence. Then promote the LATEST-dated fit of each main model to
`inputs/fit/` (the recovery, BF and PPC scripts read from there). The pipeline groups the listing by
model (name after the date prefix) and copies only the newest file of each, so stale earlier dates and
pre-resume fits stay behind (PowerShell; `_sd` sensitivity fits are excluded by the pattern):

```powershell
$src = "s3://jon-nir/paf-models/results/fit/"
aws s3 ls $src | ForEach-Object { ($_ -split '\s+')[-1] } |
  Where-Object { $_ -match '^\d{6}_pt_[A-Za-z]+\.rds$' } |
  Group-Object { $_.Substring(7) } |
  ForEach-Object { ($_.Group | Sort-Object)[-1] } |
  ForEach-Object { aws s3 cp "$src$_" "s3://jon-nir/paf-models/inputs/fit/$_" }
```

---

## Step 2: parameter recovery (cloud + local)

Simulations are truncated to 0.23-1.0 s (`SIM_RT_WINDOW`) and the dropped fraction is logged. Per
generating model, `N` simulations (bash):

```bash
FIT=<DATE>_pt_vB.rds; N=3
nohup bash -c "for k in \$(seq 1 $N); do
  env BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/run_recovery.sh $FIT \$k
done" > ~/recovery_${FIT%.rds}.log 2>&1 &
```

Download and evaluate (PowerShell):

```powershell
aws s3 sync s3://jon-nir/paf-models/results/recovery/ outputs\models\fit_recovery\ --exclude "*" --include "*pt_*"
Rscript -e "N_SIMS <- 3L; source('R/eval/recovery.R')"
Rscript -e "source('R/eval/review_convergence_and_recovery.R')"
```

**2.9 STOP (PI):** is the `B` locus recoverable; is the truncation bias on `B`, `A`, `t0` and the PrevTar
effects material (if yes: custom truncated likelihood, F5); how many simulations for step 3.

---

## Step 3: model recovery, 8 x 8 (cloud + local)

For one generating model, refit each simulation with every candidate (the same-model fits from step 2
are reused, so the loop skips the generating model).

**Wall time:** each refit is a full fit to convergence (hours), and the loop is sequential: 7 candidates x
`N` simulations = 21 refits per generating model at `N = 3`, on one instance. Split the work by listing a
subset of candidates in `CANDS` per instance (the subsets together must cover all 8 models; the
generating model is skipped wherever it appears), e.g. instance 1 `CANDS="pt_null pt_v pt_A pt_B"`,
instance 2 `CANDS="pt_vA pt_vB pt_AB pt_vAB"`. Each instance runs (bash):

```bash
GEN=pt_vB; FIT=<DATE>_pt_vB.rds; N=3
CANDS="pt_null pt_v pt_A pt_B"
nohup bash -c "for k in \$(seq 1 $N); do for c in $CANDS; do
  [ \"\$c\" = \"$GEN\" ] && continue
  env BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/run_recovery.sh $FIT \$k --fit-model-script R/fit/\$c.R
done; done" > ~/modelrec_${GEN}_1.log 2>&1 &
```

Marginal likelihood of the LATEST-dated recovery fit of every simulation x candidate of that generating
model (bash; a script file avoids nested quoting; `true_alpha` files do not match the pattern):

```bash
GEN=pt_vB
cat > ~/bf_recovery.sh <<EOF
for f in \$(aws s3 ls s3://jon-nir/paf-models/results/recovery/ | awk '{print \$4}' \\
    | grep -E '^[0-9]{6}_${GEN}_recovery_sim[0-9]+(_fit_pt_[A-Za-z]+)?\.rds\$' \\
    | sort | awk '{ f[substr(\$0, 8)] = \$0 } END { for (k in f) print f[k] }'); do
  env BUCKET=jon-nir/paf-models CLOUD=aws FIT_PREFIX=results/recovery FIT_DIR=outputs/models/fit_recovery \\
    ./scripts/run_bf.sh \$f
done
EOF
nohup bash ~/bf_recovery.sh > ~/bf_recovery_$GEN.log 2>&1 &
```

Download and evaluate (PowerShell; the 8 main fits must also be in `outputs\models\fit\`):

```powershell
aws s3 sync s3://jon-nir/paf-models/results/recovery/ outputs\models\fit_recovery\ --exclude "*" --include "*pt_*"
aws s3 sync s3://jon-nir/paf-models/results/bf/ outputs\models\fit_bf\ --exclude "*" --include "*pt_*"
Rscript -e "N_SIMS <- 3L; source('R/eval/model_recovery.R')"
```

**3.9 STOP:** confusion matrix (`outputs/evaluation/model_recovery/`): can the BF separate `v`, `B` and `A`?
Check `margin` vs `spread` and `n_split_warnings`.

---

## Step 4: model comparison (cloud + local)

Marginal likelihood of the LATEST-dated fit of each main model (bash; the pattern excludes the `_sd`
sensitivity fits; `bf_main.sh` is written with a quoted heredoc, so it is stored verbatim):

```bash
cat > ~/bf_main.sh <<'EOF'
for f in $(aws s3 ls s3://jon-nir/paf-models/inputs/fit/ | awk '{print $4}' \
    | grep -E '^[0-9]{6}_pt_[A-Za-z]+\.rds$' \
    | sort | awk '{ f[substr($0, 8)] = $0 } END { for (k in f) print f[k] }'); do
  env BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/run_bf.sh $f
done
EOF
nohup bash ~/bf_main.sh > ~/bf_main.log 2>&1 &
```

Bayes factors, then DIC/BPIC/LOO (PowerShell):

```powershell
aws s3 sync s3://jon-nir/paf-models/results/bf/ outputs\models\fit_bf\ --exclude "*" --include "*pt_*"
Rscript -e "source('R/eval/bayes_factors.R')"
Rscript -e "source('R/eval/goodness_of_fit.R')"
```

### Prior sensitivity (top models)

`PT_PRIOR_SD_SCALE` (an environment variable, set before R starts) multiplies the SDs of all EFFECT priors
(`PT_PRIOR_SD`, including the shared nuisance effect `sv_TargetAtLocTRUE`; never the `v`/`B`/`A`/`t0` (`PT_INTERCEPT_SD`)
intercepts) and appends `_sd<scale>` to the model name (`1`, `1.0` or unset = no suffix; `.5` and `0.5` =
`_sd0.5`; `2` = `_sd2`; anything non-numeric or <= 0 is an error), so these fits never clobber the main ones.

It must be set on every command that **builds or looks up a model by name**: `run_fit.sh --model-script`,
`run_recovery.sh`, `run_ppc.sh` (`fit_recovery_cloud.R` / `fit_ppc_cloud.R` find the script by model name),
and locally `R/eval/ppc.R`, `R/eval/recovery.R` (finds the script for `model_unidentifiable_pattern()`) and
`R/eval/prior_predictive.R`. It is not needed by `run_bf.sh`, `bayes_factors.R`, `convergence.R`,
`goodness_of_fit.R` or `model_recovery.R`, which only read fitted files (bayes_factors does not look up
scripts).

1. Fit the scaled variants (bash; one model, two scales, sequential):

```bash
MODEL=pt_vB
nohup bash -c "for s in 0.5 2; do
  env PT_PRIOR_SD_SCALE=\$s BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/run_fit.sh --model-script R/fit/$MODEL.R
done" > ~/sens_$MODEL.log 2>&1 &
```

2. Marginal likelihood of the latest-dated scaled fits (bash; they are on `results/fit/`, so promote
them to `inputs/fit/` first from PowerShell with the step 1.9 pipeline, changing the pattern to
`'^\d{6}_pt_[A-Za-z]+_sd[0-9.]+\.rds$'`; no `PT_PRIOR_SD_SCALE` needed):

```bash
cat > ~/bf_sens.sh <<'EOF'
for f in $(aws s3 ls s3://jon-nir/paf-models/inputs/fit/ | awk '{print $4}' \
    | grep -E '^[0-9]{6}_pt_[A-Za-z]+_sd[0-9.]+\.rds$' \
    | sort | awk '{ f[substr($0, 8)] = $0 } END { for (k in f) print f[k] }'); do
  env BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/run_bf.sh $f
done
EOF
nohup bash ~/bf_sens.sh > ~/bf_sens.log 2>&1 &
```

3. Compare (PowerShell). The scaled fits may sit in `outputs\models\fit\` next to the main ones: the eval
default `MODEL_EXCLUDE_PATTERN = "_sd[0-9.]+$"` (`R/eval/eval_config.R`) keeps them out of every
`discover_model_names()` default, while an explicit `MODEL_NAMES` may name them. Writing to a separate
`BF_DIR` keeps this comparison from overwriting the main `bayes_factors.{rds,csv}`:

```powershell
aws s3 sync s3://jon-nir/paf-models/inputs/fit/ outputs\models\fit\ --exclude "*" --include "*pt_vB*"
aws s3 sync s3://jon-nir/paf-models/results/bf/ outputs\models\fit_bf\ --exclude "*" --include "*pt_vB*"
Rscript -e "MODEL_NAMES <- c('pt_vB', 'pt_vB_sd0.5', 'pt_vB_sd2'); BF_REFERENCE <- 'pt_vB'; BF_DIR <- 'outputs/evaluation/bayes_factors_sensitivity'; source('R/eval/bayes_factors.R')"
```

Repeat per top model (a different `MODEL_NAMES` triplet), or pass all of them at once. The ranking is
robust if the log Bayes factors between the structural variants keep their order across the scales.

**4.9 STOP (PI):** model ranking (co-winners allowed).

---

## Step 5: posterior predictive checks (cloud + local)

Simulations are truncated to the RT window; cells are experiment x difficulty x target repeat
(`PPC_GROUP_VARS`). Per model (bash):

```bash
FIT=<DATE>_pt_vB.rds
nohup env BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/run_ppc.sh $FIT > ~/ppc_${FIT%.rds}.log 2>&1 &
```

```powershell
aws s3 sync s3://jon-nir/paf-models/results/ppc/ outputs\models\fit_ppc\ --exclude "*" --include "*pt_*"
Rscript -e "source('R/eval/ppc.R')"
```

**5.9 STOP:** interpretation; Phase 2 (cue) decision.
