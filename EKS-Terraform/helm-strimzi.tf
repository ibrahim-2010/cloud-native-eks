# ──────────────────────────────────────────────
#  Strimzi Kafka Operator
#  Installs the operator + CRDs into the kafka namespace.
#  The Kafka cluster CR is managed by ArgoCD (Kubernetes-Manifests-file/Kafka/).
# ──────────────────────────────────────────────

resource "kubernetes_namespace" "kafka" {
  metadata {
    name = "kafka"
    labels = {
      "app.kubernetes.io/managed-by" = "Terraform"
    }
  }

  depends_on = [aws_eks_node_group.main]
}

resource "helm_release" "strimzi" {
  name       = "strimzi"
  repository = "https://strimzi.io/charts/"
  chart      = "strimzi-kafka-operator"
  version    = "0.42.0"
  namespace  = kubernetes_namespace.kafka.metadata[0].name

  set {
    name  = "watchAnyNamespace"
    value = "false"
  }

  depends_on = [kubernetes_namespace.kafka]
}
