# ──────────────────────────────────────────────
#  External Secrets Operator
#  Watches ExternalSecret CRs and syncs values
#  from AWS Secrets Manager into Kubernetes Secrets.
#  Replaces: kubectl create secret generic nimbus-secrets
# ──────────────────────────────────────────────

resource "helm_release" "eso" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = "nimbus"
  timeout    = 300
  wait       = true

  set {
    name  = "installCRDs"
    value = "true"
  }

  # Annotate the ESO service account with the IRSA role ARN
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.eso.arn
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.eso_secrets,
    kubernetes_namespace.nimbus,
  ]
}
