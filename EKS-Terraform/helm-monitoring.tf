# ──────────────────────────────────────────────
#  Monitoring Stack — Prometheus + Grafana
#  Installed via Terraform Helm provider which
#  handles CRDs correctly (unlike ArgoCD Helm)
#
#  Replaces: helm install monitoring prometheus-community/...
#  Also replaces: argocd/apps/monitoring-stack.yaml
# ──────────────────────────────────────────────

resource "helm_release" "monitoring" {
  name       = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = "monitoring"
  version    = "72.6.2"

  # Wait for CRDs to be installed before creating resources
  skip_crds       = false
  create_namespace = false
  timeout          = 600

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          storageSpec = null
          resources = {
            requests = {
              memory = "512Mi"
              cpu    = "250m"
            }
          }
        }
      }
      alertmanager = {
        alertmanagerSpec = {
          storage = null
        }
      }
      grafana = {
        service = {
          type = "LoadBalancer"
        }
        adminPassword = "CloudNative2026!"
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.monitoring,
    aws_eks_node_group.main,
  ]
}
