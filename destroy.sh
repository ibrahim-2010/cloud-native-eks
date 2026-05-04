#!/bin/bash
set -euo pipefail
# =============================================================================
#  Cloud-Native EKS — Full Stack Destroy Script
#
#  Tears down ALL resources in the correct order to avoid orphans.
#  Run from a machine with AWS CLI configured and kubectl access.
#
#  Usage: bash destroy.sh [--skip-confirmation]
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLUSTER_NAME="cloud-native-cluster"
REGION="us-east-1"

echo -e "${RED}"
echo "╔══════════════════════════════════════════════════╗"
echo "║         FULL STACK DESTROY                       ║"
echo "║  This will DELETE all AWS resources.              ║"
echo "║  EKS cluster, ALB, ECR images, Route 53 records  ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

if [[ "${1:-}" != "--skip-confirmation" ]]; then
  read -p "Are you sure? Type 'destroy' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "destroy" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

echo ""

# ──────────────────────────────────────────────
#  Phase 1: Kubernetes Resources
# ──────────────────────────────────────────────
echo -e "${YELLOW}[1/7] Deleting ArgoCD applications...${NC}"
kubectl delete applications --all -n argocd 2>/dev/null || echo "  No ArgoCD apps found"

echo -e "${YELLOW}[2/7] Deleting monitoring stack...${NC}"
helm uninstall monitoring -n monitoring 2>/dev/null || echo "  No monitoring release found"

echo -e "${YELLOW}[3/7] Deleting ArgoCD...${NC}"
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  2>/dev/null || echo "  ArgoCD already removed"

echo -e "${YELLOW}[4/7] Deleting application resources...${NC}"
kubectl delete all --all -n three-tier 2>/dev/null || echo "  Namespace already clean"
kubectl delete pvc --all -n three-tier 2>/dev/null || echo "  No PVCs found"
kubectl delete ingress --all -n three-tier 2>/dev/null || echo "  No ingress found"

# Wait for ALB to be deleted before destroying infrastructure
echo "  Waiting 60s for ALB cleanup..."
sleep 60

# ──────────────────────────────────────────────
#  Phase 2: EKS Infrastructure (Terraform)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[5/7] Destroying EKS infrastructure (Terraform)...${NC}"
if [ -d "EKS-Terraform" ]; then
  cd EKS-Terraform
  terraform init -backend-config="bucket=ibrahim-cloud-native-tf-state" \
    -backend-config="key=eks/terraform.tfstate" \
    -backend-config="region=us-east-1" \
    -backend-config="dynamodb_table=ibrahim-cloud-native-tf-lock" \
    2>/dev/null || true
  terraform destroy -auto-approve
  cd ..
else
  echo "  EKS-Terraform directory not found — skipping"
  echo "  Manual cleanup: eksctl delete cluster --name $CLUSTER_NAME --region $REGION"
fi

# ──────────────────────────────────────────────
#  Phase 3: ECR Repositories
# ──────────────────────────────────────────────
echo -e "${YELLOW}[6/7] Deleting ECR repositories...${NC}"
aws ecr delete-repository --repository-name frontend --region $REGION --force 2>/dev/null \
  || echo "  frontend repo already deleted"
aws ecr delete-repository --repository-name backend --region $REGION --force 2>/dev/null \
  || echo "  backend repo already deleted"

# ──────────────────────────────────────────────
#  Phase 4: Jenkins Server (Terraform)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[7/7] Destroying Jenkins server (Terraform)...${NC}"
if [ -d "Jenkins-Server-TF" ]; then
  cd Jenkins-Server-TF
  terraform init -backend-config="bucket=ibrahim-cloud-native-tf-state" \
    -backend-config="key=jenkins/terraform.tfstate" \
    -backend-config="region=us-east-1" \
    -backend-config="dynamodb_table=ibrahim-cloud-native-tf-lock" \
    2>/dev/null || true
  terraform destroy -auto-approve
  cd ..
else
  echo "  Jenkins-Server-TF directory not found — skipping"
fi

# ──────────────────────────────────────────────
#  Summary
# ──────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
echo "║         DESTROY COMPLETE                          ║"
echo "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "Manual verification required:"
echo "  - EC2: No running instances"
echo "  - EBS: No orphan volumes"
echo "  - ELB: No load balancers"
echo "  - CloudFormation: All stacks deleted"
echo "  - Elastic IPs: None allocated"
echo "  - NAT Gateways: None active"
echo "  - Route 53: Hosted zone (keep if you want the domain)"
echo ""
echo "Optional — delete Terraform state backend:"
echo "  aws s3 rb s3://ibrahim-cloud-native-tf-state --force"
echo "  aws dynamodb delete-table --table-name ibrahim-cloud-native-tf-lock --region $REGION"
