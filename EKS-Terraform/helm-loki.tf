# ──────────────────────────────────────────────
#  Loki Stack — log aggregation for EKS
#  loki-stack deploys both Loki and Promtail.
#  Promtail runs as a DaemonSet and ships all
#  pod logs to Loki. Grafana (already deployed)
#  is configured to use Loki as a datasource
#  via helm-monitoring.tf additionalDataSources.
# ──────────────────────────────────────────────

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki-stack"
  namespace  = "monitoring"
  timeout    = 600
  wait       = false

  values = [yamlencode({
    loki = {
      enabled = true
      persistence = { enabled = false }
      resources = {
        requests = { memory = "128Mi", cpu = "50m" }
        limits   = { memory = "256Mi", cpu = "200m" }
      }
    }
    promtail = {
      enabled = true
      resources = {
        requests = { memory = "64Mi", cpu = "25m" }
        limits   = { memory = "128Mi", cpu = "100m" }
      }
    }
    # Grafana is already deployed by kube-prometheus-stack
    grafana = { enabled = false }
  })]

  depends_on = [helm_release.monitoring]
}
