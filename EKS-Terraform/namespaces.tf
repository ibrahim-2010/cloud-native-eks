# ──────────────────────────────────────────────
#  Kubernetes Provider + Namespaces
#  Replaces: kubectl create namespace (x3)
# ──────────────────────────────────────────────

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
    }
  }
}

resource "kubernetes_namespace" "three_tier" {
  metadata {
    name = "three-tier"
    labels = {
      project = "cloud-native-eks"
    }
  }

  depends_on = [aws_eks_node_group.main]
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      project = "cloud-native-eks"
    }
  }

  depends_on = [aws_eks_node_group.main]
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      project = "cloud-native-eks"
    }
  }

  depends_on = [aws_eks_node_group.main]
}

resource "kubernetes_namespace" "nimbus" {
  metadata {
    name = "nimbus"
    labels = {
      project = "cloud-native-eks"
    }
  }

  depends_on = [aws_eks_node_group.main]
}
