# ──────────────────────────────────────────────
#  Monitoring Stack — Prometheus + Grafana
#  Installed via Terraform Helm provider which
#  handles CRDs correctly (unlike ArgoCD Helm)
#
#  FIXES APPLIED:
#    - timeout 900s (was 600s — CRD creation is slow)
#    - wait_for_jobs = true (wait for hooks to complete)
#    - No pinned chart version (uses latest stable)
#    - Grafana ClusterIP (ALB Ingress handles external access)
#    - Reduced resource requests (fits on t3.xlarge nodes)
#    - Depends on ALB controller being ready
# ──────────────────────────────────────────────

resource "helm_release" "monitoring" {
  name             = "monitoring"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = false
  skip_crds        = false
  timeout          = 900
  wait             = true
  wait_for_jobs    = true

  values = [
    yamlencode({
      prometheus = {
        prometheusSpec = {
          storageSpec = null
          resources = {
            requests = {
              memory = "256Mi"
              cpu    = "100m"
            }
          }
        }
      }
      alertmanager = {
        alertmanagerSpec = {
          storage = null
          resources = {
            requests = {
              memory = "128Mi"
              cpu    = "50m"
            }
          }
        }
      }
      grafana = {
        service = {
          type = "ClusterIP"
        }
        adminPassword = "CloudNative2026!"
        resources = {
          requests = {
            memory = "128Mi"
            cpu    = "50m"
          }
        }
      }
      prometheusOperator = {
        resources = {
          requests = {
            memory = "128Mi"
            cpu    = "50m"
          }
        }
      }
      kube-state-metrics = {
        resources = {
          requests = {
            memory = "64Mi"
            cpu    = "25m"
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.monitoring,
    aws_eks_node_group.main,
    helm_release.alb_controller,
  ]
}
