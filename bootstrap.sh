#!/bin/bash
set -euo pipefail
# =============================================================================
#  Cloud-Native EKS — Bootstrap Script
#  Creates ALL prerequisite AWS resources before any Terraform runs.
#  Run this ONCE on a fresh AWS account.
#
#  Creates: S3 bucket, DynamoDB table, ECR repos, EC2 key pair
#
#  Usage: bash bootstrap.sh
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REGION="us-east-1"
S3_BUCKET="ibrahim-cloud-native-tf-state"
DYNAMO_TABLE="ibrahim-cloud-native-tf-lock"
KEY_NAME="test"

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║     Cloud-Native EKS — Bootstrap                 ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── S3 Bucket for Terraform State ───────────────────────────────────────────
echo -e "${YELLOW}[1/5] Creating S3 bucket for Terraform state...${NC}"
if aws s3api head-bucket --bucket "$S3_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  Bucket $S3_BUCKET already exists — skipping"
else
  aws s3api create-bucket --bucket "$S3_BUCKET" --region "$REGION"
  aws s3api put-bucket-versioning \
    --bucket "$S3_BUCKET" \
    --versioning-configuration Status=Enabled
  echo "  Created and versioning enabled: $S3_BUCKET"
fi

# ─── DynamoDB Table for State Locking ────────────────────────────────────────
echo -e "${YELLOW}[2/5] Creating DynamoDB table for state locking...${NC}"
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --region "$REGION" 2>/dev/null | grep -q "ACTIVE"; then
  echo "  Table $DYNAMO_TABLE already exists — skipping"
else
  aws dynamodb create-table \
    --table-name "$DYNAMO_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"
  echo "  Created: $DYNAMO_TABLE"
  echo "  Waiting for table to become active..."
  aws dynamodb wait table-exists --table-name "$DYNAMO_TABLE" --region "$REGION"
fi

# ─── ECR Repositories ───────────────────────────────────────────────────────
echo -e "${YELLOW}[3/5] Creating ECR repositories...${NC}"
for REPO in frontend backend; do
  if aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" 2>/dev/null | grep -q "$REPO"; then
    echo "  ECR repo $REPO already exists — skipping"
  else
    aws ecr create-repository --repository-name "$REPO" --region "$REGION" > /dev/null
    echo "  Created: $REPO"
  fi
done

# ─── EC2 Key Pair ────────────────────────────────────────────────────────────
echo -e "${YELLOW}[4/5] Creating EC2 key pair...${NC}"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" 2>/dev/null | grep -q "$KEY_NAME"; then
  echo "  Key pair $KEY_NAME already exists — skipping"
else
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text \
    --region "$REGION" > "${KEY_NAME}.pem"
  chmod 400 "${KEY_NAME}.pem"
  echo "  Created: ${KEY_NAME}.pem (save this file securely)"
fi

# ─── Verify AWS Identity ────────────────────────────────────────────────────
echo -e "${YELLOW}[5/5] Verifying AWS identity...${NC}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  Account: $ACCOUNT_ID"
echo "  Region: $REGION"

# ─── Clean orphan Jenkins resources from previous deployments ────────────────
echo -e "${YELLOW}[6/6] Cleaning orphan Jenkins resources...${NC}"
aws iam remove-role-from-instance-profile --instance-profile-name jenkins-cloud-native-profile --role-name jenkins-cloud-native-role 2>/dev/null
aws iam delete-instance-profile --instance-profile-name jenkins-cloud-native-profile 2>/dev/null
for ARN in $(aws iam list-attached-role-policies --role-name jenkins-cloud-native-role --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name jenkins-cloud-native-role --policy-arn "$ARN" 2>/dev/null
done
for NAME in $(aws iam list-role-policies --role-name jenkins-cloud-native-role --query "PolicyNames[]" --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name jenkins-cloud-native-role --policy-name "$NAME" 2>/dev/null
done
aws iam delete-role --role-name jenkins-cloud-native-role 2>/dev/null
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=jenkins-cloud-native-sg" --query "SecurityGroups[0].GroupId" --output text --region us-east-1 2>/dev/null)
[ -n "$SG_ID" ] && [ "$SG_ID" != "None" ] && aws ec2 delete-security-group --group-id "$SG_ID" --region us-east-1 2>/dev/null
echo "  Orphan cleanup complete"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
echo "║         BOOTSTRAP COMPLETE                        ║"
echo "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Resources created:"
echo "  S3 Bucket:      $S3_BUCKET"
echo "  DynamoDB Table:  $DYNAMO_TABLE"
echo "  ECR Repos:       frontend, backend"
echo "  Key Pair:        $KEY_NAME"
echo "  Account ID:      $ACCOUNT_ID"
echo ""
echo "Next steps:"
echo "  1. cd Jenkins-Server-TF && terraform init && terraform apply -auto-approve"
echo "  2. cd EKS-Terraform && terraform init && terraform apply -auto-approve"
