# ──────────────────────────────────────────────
#  IRSA — External Secrets Operator
#
#  ESO uses a single IAM role (eso-role) to read
#  from Secrets Manager on behalf of all Nimbus
#  services. Individual service accounts do not
#  need AWS access — only ESO does.
#
#  local.oidc_provider + local.oidc_provider_arn
#  are defined in ebs-csi.tf.
# ──────────────────────────────────────────────

# IAM policy — read any secret under the cluster prefix
resource "aws_iam_policy" "nimbus_secrets_reader" {
  name        = "${var.cluster_name}-nimbus-secrets-reader"
  description = "Allow ESO to read Nimbus secrets from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.cluster_name}/*"
    }]
  })
}

# IAM role assumed by the ESO controller service account
resource "aws_iam_role" "eso" {
  name = "${var.cluster_name}-eso-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
          # ESO creates a service account named "external-secrets" in its namespace
          "${local.oidc_provider}:sub" = "system:serviceaccount:nimbus:external-secrets"
        }
      }
    }]
  })

  tags = { Project = "nimbus-retail" }
}

resource "aws_iam_role_policy_attachment" "eso_secrets" {
  policy_arn = aws_iam_policy.nimbus_secrets_reader.arn
  role       = aws_iam_role.eso.name
}
