library(loo)
library(ggplot2)
source(file.path(getwd(), "R", "utils.R"))
source_root("R/eval/eval_config.R")
source_root("R/eval/helpers/plot.R")

MODEL_NAMES <- c("model1", "model2", "model4", "model5")

loo_objs <- lapply(MODEL_NAMES, function(nm)
  readRDS(file.path(LOO_DIR, paste0(nm, "_loo.rds"))))
names(loo_objs) <- MODEL_NAMES

LOO_COMPARISON <- readRDS(file.path(LOO_DIR, "loo_comparison.rds"))

pareto_df <- do.call(rbind, lapply(MODEL_NAMES, function(nm)
  data.frame(model = nm,
             k_hat = loo_objs[[nm]]$diagnostics$pareto_k,
             stringsAsFactors = FALSE)))

save_ggplot_png(plot_pareto_k(pareto_df),
                file.path(LOO_DIR, "pareto_k_per_model.png"), height = 6)
save_ggplot_png(plot_loo_comparison(LOO_COMPARISON),
                file.path(LOO_DIR, "loo_comparison.png"), width = 7, height = 5)

cat("done\n")
