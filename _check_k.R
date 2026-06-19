library(loo)
loo_dir <- "outputs/evaluation/loo"
models <- c("model1","model2","model4","model5")
for (m in models) {
  obj <- readRDS(file.path(loo_dir, paste0(m, "_loo.rds")))
  k <- obj$diagnostics$pareto_k
  cat(sprintf("%s: n=%d, min=%.4f, max=%.4f, p95=%.4f, p99=%.4f\n",
              m, length(k), min(k), max(k), quantile(k, 0.95), quantile(k, 0.99)))
}
