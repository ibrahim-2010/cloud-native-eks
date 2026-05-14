#!/bin/bash
set -euo pipefail
# =============================================================================
#  NimbusRetail — Bootstrap Script
#
#  Creates ALL prerequisite AWS resources before any Terraform runs.
#  Run this ONCE on a fresh AWS account. Fully idempotent — safe to re-run.
#
#  Creates:
#    1. S3 bucket (versioned + encrypted + public-access-blocked) — Terraform state
#    2. DynamoDB table — Terraform state locking
#    3. ECR repos (frontend, backend) — three-tier legacy; Nimbus repos via Terraform
#    4. EC2 key pair — Jenkins SSH access
#    5. AWS identity verification
#    6. Orphan Jenkins IAM/SG cleanup (from previous deployments)
#
#  Usage: bash bootstrap.sh
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

REGION="us-east-1"
S3_BUCKET="ibrahim-cloud-native-tf-state"
DYNAMO_TABLE="ibrahim-cloud-native-tf-lock"
KEY_NAME="test"

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║     NimbusRetail — Bootstrap                     ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── [1/6] S3 Bucket for Terraform State ─────────────────────────────────────
echo -e "${YELLOW}[1/6] Creating S3 bucket for Terraform state...${NC}"
if aws s3api head-bucket --bucket "$S3_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  Bucket $S3_BUCKET already exists — skipping creation"
else
  aws s3api create-bucket --bucket "$S3_BUCKET" --region "$REGION"
  echo "  Created: $S3_BUCKET"
fi

# Versioning (idempotent — safe to re-apply)
aws s3api put-bucket-versioning \
  --bucket "$S3_BUCKET" \
  --versioning-configuration Status=Enabled
echo "  Versioning: enabled"

# Server-side encryption — required for production state buckets
aws s3api put-bucket-encryption \
  --bucket "$S3_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      },
      "BucketKeyEnabled": true
    }]
  }'
echo "  Encryption: AES256 enabled"

# Block all public access — state must never be public
aws s3api put-public-access-block \
  --bucket "$S3_BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  Public access: fully blocked"

# ─── [2/6] DynamoDB Table for State Locking ──────────────────────────────────
echo -e "${YELLOW}[2/6] Creating DynamoDB table for state locking...${NC}"
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --region "$REGION" 2>/dev/null | grep -q "ACTIVE"; then
  echo "  Table $DYNAMO_TABLE already exists — skipping"
else
  aws dynamodb create-table \
    --table-name "$DYNAMO_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"
  echo "  Created: $DYNAMO_TABLE (waiting for ACTIVE...)"
  aws dynamodb wait table-exists --table-name "$DYNAMO_TABLE" --region "$REGION"
  echo "  Status: ACTIVE"
fi

# ─── [3/6] ECR Repositories ──────────────────────────────────────────────────
echo -e "${YELLOW}[3/6] Creating ECR repositories (legacy three-tier)...${NC}"
echo "  NOTE: Nimbus ECR repos (nimbus/*) are created by EKS-Terraform/ecr.tf"
for REPO in frontend backend; do
  if aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" 2>/dev/null | grep -q "$REPO"; then
    echo "  ECR repo '$REPO' already exists — skipping"
  else
    aws ecr create-repository --repository-name "$REPO" \
      --image-scanning-configuration scanOnPush=true \
      --region "$REGION" > /dev/null
    echo "  Created: $REPO (image scanning enabled)"
  fi
done

# ─── [4/6] EC2 Key Pair ──────────────────────────────────────────────────────
echo -e "${YELLOW}[4/6] Creating EC2 key pair...${NC}"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" 2>/dev/null | grep -q "$KEY_NAME"; then
  echo "  Key pair '$KEY_NAME' already exists — skipping"
else
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text \
    --region "$REGION" > "${KEY_NAME}.pem"
  chmod 400 "${KEY_NAME}.pem"
  echo "  Created: ${KEY_NAME}.pem — save this file securely, it cannot be re-downloaded"
fi

# ─── [5/6] Verify AWS Identity ───────────────────────────────────────────────
echo -e "${YELLOW}[5/6] Verifying AWS identity...${NC}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  Account: $ACCOUNT_ID"
echo "  Region:  $REGION"

# ─── [6/6] Clean Orphan Jenkins Resources ────────────────────────────────────
echo -e "${YELLOW}[6/6] Cleaning orphan Jenkins resources from previous deployments...${NC}"
aws iam remove-role-from-instance-profile \
  --instance-profile-name jenkins-cloud-native-profile \
  --role-name jenkins-cloud-native-role 2>/dev/null && echo "  Removed role from profile" || true
aws iam delete-instance-profile \
  --instance-profile-name jenkins-cloud-native-profile 2>/dev/null && echo "  Deleted instance profile" || true
for ARN in $(aws iam list-attached-role-policies \
    --role-name jenkins-cloud-native-role \
    --query "AttachedPolicies[].PolicyArn" \
    --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name jenkins-cloud-native-role --policy-arn "$ARN" 2>/dev/null || true
done
for NAME in $(aws iam list-role-policies \
    --role-name jenkins-cloud-native-role \
    --query "PolicyNames[]" \
    --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name jenkins-cloud-native-role --policy-name "$NAME" 2>/dev/null || true
done
aws iam delete-role --role-name jenkins-cloud-native-role 2>/dev/null && echo "  Deleted IAM role" || true
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=jenkins-cloud-native-sg" \
  --query "SecurityGroups[0].GroupId" \
  --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null \
    && echo "  Deleted security group: $SG_ID" || true
else
  echo "  No orphan Jenkins resources found"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
echo "║         BOOTSTRAP COMPLETE                        ║"
echo "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Resources ready:"
echo "  S3 Bucket:       $S3_BUCKET  (versioned, encrypted, public-access-blocked)"
echo "  DynamoDB Table:  $DYNAMO_TABLE"
echo "  ECR Repos:       frontend, backend  (three-tier legacy)"
echo "  Key Pair:        $KEY_NAME  → ${KEY_NAME}.pem"
echo "  Account ID:      $ACCOUNT_ID"
echo ""
echo "  Nimbus ECR repos (nimbus/auth-service etc.) are created by Terraform."
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo ""
echo "  1. Push both repos to GitHub (ArgoCD and setup-jcasc.sh read from GitHub):"
echo "     git add . && git commit -m 'feat: platform stack' && git push origin main"
echo ""
echo "  2. Deploy Jenkins server:"
echo "     cd Jenkins-Server-TF"
echo "     terraform init"
echo "     terraform plan"
echo "     terraform apply"
echo ""
echo "  3. Configure Jenkins (SSH into Jenkins EC2 after boot completes ~5 min):"
echo "     sudo tail -f /var/log/tools-install.log   # wait for 'Installation Complete'"
echo "     sudo bash /opt/setup-jcasc.sh             # injects credentials, creates 8 jobs"
echo ""
echo "  4. Trigger the infrastructure pipeline in Jenkins UI:"
echo "     http://<jenkins-ip>:8080  →  nimbus-infrastructure  →  Build Now"
echo ""
echo "     This single job deploys everything automatically:"
echo "       - EKS cluster + RDS + Redis + Kafka (Strimzi)"
echo "       - ESO + Kyverno + Loki + Tempo + Prometheus/Grafana"
echo "       - Configures kubectl on the Jenkins server"
echo "       - Populates AWS Secrets Manager"
echo "       - Installs ArgoCD and deploys app-of-apps"
echo ""
echo "  5. Trigger the 5 Nimbus service build jobs in Jenkins UI:"
echo "     nimbus-auth-service, nimbus-catalog-service, nimbus-cart-service,"
echo "     nimbus-order-service, nimbus-notification-service"
echo ""
echo "  See NIMBUS_DEPLOY.md (Desktop) or docs/RUNBOOK.md for the full sequence."
