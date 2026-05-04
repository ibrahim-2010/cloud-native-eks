# ──────────────────────────────────────────────
#  ExternalDNS — Helm Installation
#  Watches Ingress resources and auto-creates
#  Route 53 A records pointing to the ALB
# ──────────────────────────────────────────────

resource "kubernetes_service_account" "external_dns" {
  metadata {
    name      = "external-dns"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns.arn
    }
  }

  depends_on = [aws_eks_node_group.main]
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  namespace  = "kube-system"
  version    = "1.14.4"

  values = [
    yamlencode({
      provider = "aws"
      aws = {
        region = var.aws_region
        zoneType = "public"
      }
      domainFilters = [var.domain_name]
      policy        = "upsert-only"
      registry      = "txt"
      txtOwnerId    = var.cluster_name
      serviceAccount = {
        create = false
        name   = "external-dns"
      }
      sources = ["ingress"]
    })
  ]

  depends_on = [
    kubernetes_service_account.external_dns,
    aws_iam_role_policy_attachment.external_dns,
    aws_eks_node_group.main,
  ]
}
