# ──────────────────────────────────────────────
#  Kyverno — Kubernetes admission controller
#  Enforces security policies on all resources
#  created in the cluster.
#  Policies live in Kubernetes-Manifests-file/Security/
#  and are deployed by ArgoCD.
# ──────────────────────────────────────────────

resource "helm_release" "kyverno" {
  name       = "kyverno"
  repository = "https://kyverno.github.io/kyverno/"
  chart      = "kyverno"
  namespace  = "kyverno"
  timeout    = 300
  wait       = true

  create_namespace = true

  set {
    name  = "replicaCount"
    value = "1"
  }

  depends_on = [
    aws_eks_node_group.main,
    helm_release.alb_controller,
  ]
}
