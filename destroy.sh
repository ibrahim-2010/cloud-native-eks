#!/bin/bash
set -uo pipefail
# =============================================================================
#  Cloud-Native EKS — Full Stack Destroy Script
#
#  ALL FIXES FROM DEPLOYMENTS 1-5:
#    - ArgoCD finalizer removal (prevents delete hang)
#    - Helm monitoring uninstall BEFORE namespace deletion
#    - All 9 monitoring CRDs deleted (prevents finalizer hang)
#    - Namespace finalizers patched (prevents Terraform timeout)
#    - Route 53 records cleaned TWICE (Phase 5 + Phase 7)
#      because ExternalDNS can recreate records between phases
#    - VPC dependencies cleaned (ALBs, ENIs, security groups)
#    - Stuck namespaces + helm_release removed from Terraform state
#    - Supports both python3 and python for Route 53 cleanup
#    - Final verification scan for orphan resources
#
#  Usage: bash destroy.sh [--skip-confirmation]
#  Run from the repo root directory with kubectl + AWS CLI access
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLUSTER_NAME="cloud-native-cluster"
REGION="us-east-1"
DOMAIN="platinum-consults.com"

echo -e "${RED}"
echo "╔══════════════════════════════════════════════════╗"
echo "║         FULL STACK DESTROY                       ║"
echo "║  This will DELETE all AWS resources.              ║"
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

# ══════════════════════════════════════════════════════════════
#  Helper function: Clean Route 53 records
#  Called in Phase 5 AND Phase 7 (ExternalDNS can recreate them)
# ══════════════════════════════════════════════════════════════
clean_route53_records() {
  local ZONE_ID=$(aws route53 list-hosted-zones \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id" \
    --output text --region $REGION 2>/dev/null | sed 's|/hostedzone/||')

  if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
    echo "  No hosted zone found — skipping"
    return 0
  fi

  echo "  Found hosted zone: $ZONE_ID"

  local RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Type!='NS' && Type!='SOA']" --output json 2>/dev/null)

  local RECORD_COUNT=$(echo "$RECORDS" | grep -c '"Name"' 2>/dev/null || echo "0")

  if [ "$RECORD_COUNT" -eq 0 ] || [ "$RECORD_COUNT" = "0" ]; then
    echo "  No extra records to delete"
    return 0
  fi

  echo "  Deleting $RECORD_COUNT records..."

  # Try python3 first, fall back to python (Windows compatibility)
  local CHANGE_BATCH=$(echo "$RECORDS" | python3 -c "
import json, sys
records = json.load(sys.stdin)
changes = [{'Action':'DELETE','ResourceRecordSet':r} for r in records]
if changes: print(json.dumps({'Changes': changes}))
" 2>/dev/null || echo "$RECORDS" | python -c "
import json, sys
records = json.load(sys.stdin)
changes = [{'Action':'DELETE','ResourceRecordSet':r} for r in records]
if changes: print(json.dumps({'Changes': changes}))
" 2>/dev/null || echo "")

  if [ -n "$CHANGE_BATCH" ]; then
    echo "$CHANGE_BATCH" | aws route53 change-resource-record-sets \
      --hosted-zone-id "$ZONE_ID" --change-batch file:///dev/stdin 2>/dev/null \
      && echo "  Records deleted successfully" \
      || echo "  Record deletion failed — may need manual cleanup"
    sleep 10
  else
    echo "  Could not build change batch — python may not be available"
  fi
}

# ──────────────────────────────────────────────
#  Phase 1: ArgoCD Applications
# ──────────────────────────────────────────────
echo -e "${YELLOW}[1/9] Deleting ArgoCD applications...${NC}"
for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do
  kubectl patch $app -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
done
kubectl delete applications --all -n argocd --timeout=60s 2>/dev/null || echo "  No ArgoCD apps found"

# ──────────────────────────────────────────────
#  Phase 2: Monitoring Stack (Helm + CRDs)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[2/9] Deleting monitoring stack...${NC}"

# Uninstall Helm release FIRST
helm uninstall monitoring -n monitoring 2>/dev/null || echo "  No monitoring Helm release"

# Delete custom resources before CRDs
kubectl delete prometheuses --all -n monitoring 2>/dev/null
kubectl delete alertmanagers --all -n monitoring 2>/dev/null
kubectl delete thanosrulers --all -n monitoring 2>/dev/null

# Delete ALL monitoring CRDs (removes finalizers that block namespace deletion)
echo "  Cleaning up monitoring CRDs..."
for crd in prometheuses.monitoring.coreos.com \
           alertmanagers.monitoring.coreos.com \
           thanosrulers.monitoring.coreos.com \
           prometheusagents.monitoring.coreos.com \
           scrapeconfigs.monitoring.coreos.com \
           servicemonitors.monitoring.coreos.com \
           podmonitors.monitoring.coreos.com \
           prometheusrules.monitoring.coreos.com \
           probes.monitoring.coreos.com; do
  kubectl delete crd "$crd" 2>/dev/null && echo "    Deleted: $crd"
done

# Force delete monitoring namespace
kubectl patch namespace monitoring -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
kubectl delete namespace monitoring --timeout=30s 2>/dev/null || echo "  Monitoring namespace already gone"
sleep 10

# ──────────────────────────────────────────────
#  Phase 3: ArgoCD
# ──────────────────────────────────────────────
echo -e "${YELLOW}[3/9] Deleting ArgoCD...${NC}"
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --timeout=60s 2>/dev/null || echo "  ArgoCD already removed"
kubectl patch namespace argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
kubectl delete namespace argocd --timeout=30s 2>/dev/null || echo "  ArgoCD namespace already gone"

# ──────────────────────────────────────────────
#  Phase 4: Application Resources
# ──────────────────────────────────────────────
echo -e "${YELLOW}[4/9] Deleting application resources...${NC}"
kubectl delete ingress --all -n three-tier 2>/dev/null || echo "  No app ingress found"
kubectl delete ingress --all -n monitoring 2>/dev/null || echo "  No monitoring ingress found"
echo "  Waiting 60s for ALB cleanup..."
sleep 60
kubectl delete all --all -n three-tier 2>/dev/null || echo "  Namespace already clean"
kubectl delete pvc --all -n three-tier 2>/dev/null || echo "  No PVCs found"
kubectl delete secrets --all -n three-tier 2>/dev/null || echo "  No secrets found"
kubectl patch namespace three-tier -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
kubectl delete namespace three-tier --timeout=30s 2>/dev/null || echo "  three-tier namespace already gone"

# ──────────────────────────────────────────────
#  Phase 5: Route 53 Record Cleanup (first pass)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[5/9] Cleaning up Route 53 records (first pass)...${NC}"
clean_route53_records

# ──────────────────────────────────────────────
#  Phase 6: VPC Dependency Cleanup
# ──────────────────────────────────────────────
echo -e "${YELLOW}[6/9] Cleaning up VPC dependencies...${NC}"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=cloud-native-eks" \
  --query "Vpcs[0].VpcId" --output text --region $REGION 2>/dev/null)

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "  Found VPC: $VPC_ID"

  # Delete load balancers
  for ALB_ARN in $(aws elbv2 describe-load-balancers --region $REGION \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
    echo "  Deleting ALB: $ALB_ARN"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region $REGION 2>/dev/null
  done
  sleep 30

  # Delete ENIs
  for ENI_ID in $(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region $REGION 2>/dev/null); do
    echo "  Deleting ENI: $ENI_ID"
    aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region $REGION 2>/dev/null
  done

  # Delete non-default security groups
  for SG_ID in $(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region $REGION 2>/dev/null); do
    echo "  Deleting SG: $SG_ID"
    aws ec2 delete-security-group --group-id "$SG_ID" --region $REGION 2>/dev/null
  done
else
  echo "  No project VPC found — skipping"
fi

# ──────────────────────────────────────────────
#  Phase 7: EKS Infrastructure (Terraform)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[7/9] Destroying EKS infrastructure (Terraform)...${NC}"
EKS_DIR=""
if [ -d "EKS-Terraform" ]; then EKS_DIR="EKS-Terraform"
elif [ -d "../EKS-Terraform" ]; then EKS_DIR="../EKS-Terraform"
fi

if [ -n "$EKS_DIR" ]; then
  cd "$EKS_DIR"

  # Remove resources that were already deleted or will cause timeout
  terraform state rm kubernetes_namespace.monitoring 2>/dev/null
  terraform state rm kubernetes_namespace.argocd 2>/dev/null
  terraform state rm kubernetes_namespace.three_tier 2>/dev/null
  terraform state rm helm_release.monitoring 2>/dev/null

  terraform init 2>/dev/null

  # Clean Route 53 records AGAIN right before destroy
  # ExternalDNS may have recreated records between Phase 5 and now
  echo "  Cleaning Route 53 records before Terraform destroy (second pass)..."
  clean_route53_records

  terraform destroy -auto-approve || echo "  Terraform destroy had errors"
  cd - > /dev/null
else
  echo "  EKS-Terraform directory not found — skipping"
fi

# ──────────────────────────────────────────────
#  Phase 8: ECR Repositories
# ──────────────────────────────────────────────
echo -e "${YELLOW}[8/9] Deleting ECR repositories...${NC}"
aws ecr delete-repository --repository-name frontend --region $REGION --force 2>/dev/null \
  && echo "  Deleted: frontend" || echo "  frontend already deleted"
aws ecr delete-repository --repository-name backend --region $REGION --force 2>/dev/null \
  && echo "  Deleted: backend" || echo "  backend already deleted"

# ──────────────────────────────────────────────
#  Phase 9: Jenkins Server (Terraform)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[9/9] Destroying Jenkins server (Terraform)...${NC}"
JENKINS_DIR=""
if [ -d "Jenkins-Server-TF" ]; then JENKINS_DIR="Jenkins-Server-TF"
elif [ -d "../Jenkins-Server-TF" ]; then JENKINS_DIR="../Jenkins-Server-TF"
fi

if [ -n "$JENKINS_DIR" ]; then
  cd "$JENKINS_DIR"
  terraform init 2>/dev/null
  terraform destroy -auto-approve || echo "  Terraform destroy had errors"
  cd - > /dev/null
fi

# Clean up any orphan Jenkins resources that Terraform missed
echo "  Cleaning orphan Jenkins resources..."

# Delete instance profile
aws iam remove-role-from-instance-profile \
  --instance-profile-name jenkins-cloud-native-profile \
  --role-name jenkins-cloud-native-role --region $REGION 2>/dev/null
aws iam delete-instance-profile \
  --instance-profile-name jenkins-cloud-native-profile --region $REGION 2>/dev/null

# Detach policies and delete role
for ARN in $(aws iam list-attached-role-policies --role-name jenkins-cloud-native-role \
  --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name jenkins-cloud-native-role --policy-arn "$ARN" 2>/dev/null
done
for NAME in $(aws iam list-role-policies --role-name jenkins-cloud-native-role \
  --query "PolicyNames[]" --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name jenkins-cloud-native-role --policy-name "$NAME" 2>/dev/null
done
aws iam delete-role --role-name jenkins-cloud-native-role --region $REGION 2>/dev/null

# Delete security group
SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=jenkins-cloud-native-sg" \
  --query "SecurityGroups[0].GroupId" --output text --region $REGION 2>/dev/null)
if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  aws ec2 delete-security-group --group-id "$SG_ID" --region $REGION 2>/dev/null
fi

echo "  Jenkins cleanup complete"

# ──────────────────────────────────────────────
#  Final Verification
# ──────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Running final verification...${NC}"
echo ""

ALL_CLEAN=true

INSTANCES=$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" --output text --region $REGION 2>/dev/null)
CLUSTERS=$(aws eks list-clusters --query "clusters" --output text --region $REGION 2>/dev/null)
VPCS=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=false" \
  --query "Vpcs[].VpcId" --output text --region $REGION 2>/dev/null)
ELBS=$(aws elbv2 describe-load-balancers --query "LoadBalancers[].DNSName" \
  --output text --region $REGION 2>/dev/null)
NATS=$(aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
  --query "NatGateways[].NatGatewayId" --output text --region $REGION 2>/dev/null)
EIPS=$(aws ec2 describe-addresses --query "Addresses[].AllocationId" \
  --output text --region $REGION 2>/dev/null)

[ -n "$INSTANCES" ] && echo -e "  ${RED}⚠ Running instances: $INSTANCES${NC}" && ALL_CLEAN=false || echo -e "  ${GREEN}✅ No running instances${NC}"
[ -n "$CLUSTERS" ] && echo -e "  ${RED}⚠ EKS clusters: $CLUSTERS${NC}" && ALL_CLEAN=false || echo -e "  ${GREEN}✅ No EKS clusters${NC}"
[ -n "$VPCS" ] && echo -e "  ${RED}⚠ Non-default VPCs: $VPCS${NC}" && ALL_CLEAN=false || echo -e "  ${GREEN}✅ No custom VPCs${NC}"
[ -n "$ELBS" ] && echo -e "  ${RED}⚠ Load balancers: $ELBS${NC}" && ALL_CLEAN=false || echo -e "  ${GREEN}✅ No load balancers${NC}"
[ -n "$NATS" ] && echo -e "  ${RED}⚠ NAT gateways: $NATS${NC}" && ALL_CLEAN=false || echo -e "  ${GREEN}✅ No NAT gateways${NC}"
[ -n "$EIPS" ] && echo -e "  ${RED}⚠ Elastic IPs: $EIPS${NC}" && ALL_CLEAN=false || echo -e "  ${GREEN}✅ No Elastic IPs${NC}"

echo ""
if [ "$ALL_CLEAN" = true ]; then
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
  echo "║         DESTROY COMPLETE — ALL CLEAN              ║"
  echo "╚══════════════════════════════════════════════════╝${NC}"
else
  echo -e "${RED}╔══════════════════════════════════════════════════╗"
  echo "║   SOME RESOURCES REMAIN — CHECK ITEMS ABOVE      ║"
  echo "╚══════════════════════════════════════════════════╝${NC}"
fi
echo ""
echo "S3 bucket and DynamoDB table preserved for future deployments."
echo "To delete permanently:"
echo "  aws s3 rb s3://ibrahim-cloud-native-tf-state --force"
echo "  aws dynamodb delete-table --table-name ibrahim-cloud-native-tf-lock --region $REGION"