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

Data and outputs live in the main checkout, so switch it to `analysis2` there:

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

**1.9 STOP:** flag severe non-convergence. Then promote each converged fit to `inputs/fit/` (the
recovery, BF and PPC scripts read from there):

```powershell
aws s3 cp s3://jon-nir/paf-models/results/fit/ s3://jon-nir/paf-models/inputs/fit/ --recursive --exclude "*" --include "*_pt_*.rds"
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
are reused, so the loop skips the generating model). One generating model per instance (bash):

```bash
GEN=pt_vB; FIT=<DATE>_pt_vB.rds; N=3
nohup bash -c "for k in \$(seq 1 $N); do for c in pt_null pt_v pt_A pt_B pt_vA pt_vB pt_AB pt_vAB; do
  [ \"\$c\" = \"$GEN\" ] && continue
  env BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/run_recovery.sh $FIT \$k --fit-model-script R/fit/\$c.R
done; done" > ~/modelrec_$GEN.log 2>&1 &
```

Marginal likelihood of every recovery fit of that generating model (bash; skips `true_alpha` files):

```bash
GEN=pt_vB
nohup bash -c "for f in \$(aws s3 ls s3://jon-nir/paf-models/results/recovery/ | awk '{print \$4}' \
    | grep -E \"^[0-9]{6}_${GEN}_recovery_sim[0-9]+(_fit_pt_[A-Za-z]+)?\.rds\$\"); do
  env BUCKET=jon-nir/paf-models CLOUD=aws FIT_PREFIX=results/recovery FIT_DIR=outputs/models/fit_recovery \
    ./scripts/run_bf.sh \$f
done" > ~/bf_recovery_$GEN.log 2>&1 &
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

Marginal likelihood of each main fit (bash):

```bash
nohup bash -c 'for f in $(aws s3 ls s3://jon-nir/paf-models/inputs/fit/ | awk "{print \$4}" \
    | grep -E "^[0-9]{6}_pt_[A-Za-z]+\.rds$"); do
  env BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/run_bf.sh $f
done' > ~/bf_main.log 2>&1 &
```

Bayes factors, then DIC/BPIC/LOO (PowerShell):

```powershell
aws s3 sync s3://jon-nir/paf-models/results/bf/ outputs\models\fit_bf\ --exclude "*" --include "*pt_*"
Rscript -e "source('R/eval/bayes_factors.R')"
Rscript -e "source('R/eval/goodness_of_fit.R')"
```

### Prior sensitivity (top models)

`PT_PRIOR_SD_SCALE` scales the effect-prior SDs and appends `_sd<scale>` to the model name, so these fits
never clobber the main ones. Set it on **every** command that builds or looks up these models (bash):

```bash
MODEL=pt_vB
nohup bash -c "for s in 0.5 2; do
  env PT_PRIOR_SD_SCALE=\$s BUCKET=jon-nir/paf-models CLOUD=aws ./scripts/run_fit.sh --model-script R/fit/$MODEL.R
done" > ~/sens_$MODEL.log 2>&1 &
```

Then promote the converged `*_sd*.rds` fits to `inputs/fit/` and run `run_bf.sh` on each, as above.
Keep sensitivity fits out of `outputs\models\fit\` during the main eval (they would be discovered as extra
models): sync them to a separate folder and compare there.

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
