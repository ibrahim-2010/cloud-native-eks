# ──────────────────────────────────────────────
#  Tempo — distributed tracing backend
#  Single-binary mode (no persistence) is
#  sufficient for a capstone. Services would
#  need OTEL SDK instrumentation to emit spans.
# ──────────────────────────────────────────────

resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  namespace  = "monitoring"
  timeout    = 300
  wait       = false

  values = [yamlencode({
    persistence = { enabled = false }
    resources = {
      requests = { memory = "128Mi", cpu = "50m" }
      limits   = { memory = "256Mi", cpu = "200m" }
    }
    tempo = {
      storage = {
        trace = { backend = "local" }
      }
    }
  })]

  depends_on = [helm_release.monitoring]
}
