# ──────────────────────────────────────────────
#  ExternalDNS — IAM Policy + Role (IRSA)
#  Automatically creates Route 53 records from
#  Ingress annotations. Replaces manual Phase 11
#  console clicking.
# ──────────────────────────────────────────────

variable "domain_name" {
  description = "Domain name for Route 53 hosted zone"
  type        = string
  default     = "platinum-consults.com"
}

# Route 53 Hosted Zone (created declaratively)
resource "aws_route53_zone" "main" {
  name = var.domain_name

  tags = {
    Project = "cloud-native-eks"
  }
}

# IAM Policy for ExternalDNS
resource "aws_iam_policy" "external_dns" {
  name        = "${var.cluster_name}-external-dns-policy"
  description = "IAM policy for ExternalDNS to manage Route 53 records"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = [
          "arn:aws:route53:::hostedzone/${aws_route53_zone.main.zone_id}"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListResourceRecordSets",
          "route53:ListTagsForResource"
        ]
        Resource = ["*"]
      }
    ]
  })

  tags = {
    Project = "cloud-native-eks"
  }
}

# IAM Role for ExternalDNS service account (IRSA)
resource "aws_iam_role" "external_dns" {
  name = "${var.cluster_name}-external-dns-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
          "${local.oidc_provider}:sub" = "system:serviceaccount:kube-system:external-dns"
        }
      }
    }]
  })

  tags = {
    Project = "cloud-native-eks"
  }
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  policy_arn = aws_iam_policy.external_dns.arn
  role       = aws_iam_role.external_dns.name
}
