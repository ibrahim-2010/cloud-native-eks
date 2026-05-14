#!/bin/bash
set -uo pipefail
# =============================================================================
#  NimbusRetail — Full Stack Destroy Script
#
#  FIXES APPLIED ACROSS ALL DEPLOYMENTS:
#    - ArgoCD finalizer removal (prevents delete hang)
#    - Helm releases uninstalled BEFORE namespace deletion
#    - All monitoring/strimzi/ESO/kyverno CRDs deleted (prevents finalizer hang)
#    - Namespace finalizers patched (prevents Terraform timeout)
#    - Route 53 records cleaned TWICE (ExternalDNS can recreate between phases)
#    - VPC dependencies cleaned (ALBs, ENIs, security groups)
#    - Stuck namespaces + helm releases removed from Terraform state
#    - Secrets Manager secrets deleted (prevent hidden ongoing cost)
#    - All ECR repos deleted (nimbus/* + legacy frontend/backend)
#    - EBS orphan volumes checked in final scan
#    - Final verification covers all billable resource types
#
#  Usage: bash destroy.sh [--skip-confirmation]
#  Run from the repo root with kubectl + AWS CLI access configured.
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLUSTER_NAME="nimbus-cluster"
REGION="us-east-1"
DOMAIN="platinum-consults.com"
TOTAL_PHASES=11

echo -e "${RED}"
echo "╔══════════════════════════════════════════════════╗"
echo "║         NIMBUS FULL STACK DESTROY                ║"
echo "║  This will DELETE all AWS resources.             ║"
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
#  Helper: Clean Route 53 records
#  Called twice — ExternalDNS can recreate records between phases.
# ══════════════════════════════════════════════════════════════
clean_route53_records() {
  local ZONE_ID
  ZONE_ID=$(aws route53 list-hosted-zones \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id" \
    --output text --region "$REGION" 2>/dev/null | sed 's|/hostedzone/||')

  if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
    echo "  No hosted zone found — skipping"
    return 0
  fi

  echo "  Found hosted zone: $ZONE_ID"
  local RECORDS
  RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Type!='NS' && Type!='SOA']" --output json 2>/dev/null)

  local RECORD_COUNT
  RECORD_COUNT=$(echo "$RECORDS" | grep -c '"Name"' 2>/dev/null || echo "0")

  if [ "$RECORD_COUNT" -eq 0 ] || [ "$RECORD_COUNT" = "0" ]; then
    echo "  No extra records to delete"
    return 0
  fi

  echo "  Deleting $RECORD_COUNT records..."
  local CHANGE_BATCH
  CHANGE_BATCH=$(echo "$RECORDS" | python3 -c "
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
      && echo "  Records deleted" \
      || echo "  Record deletion failed — may need manual cleanup"
    sleep 10
  else
    echo "  Could not build change batch — check python3 is available"
  fi
}

# ──────────────────────────────────────────────
#  Phase 1: ArgoCD Applications
# ──────────────────────────────────────────────
echo -e "${YELLOW}[1/${TOTAL_PHASES}] Removing ArgoCD applications (clear finalizers first)...${NC}"
for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do
  kubectl patch "$app" -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null
done
kubectl delete applications --all -n argocd --timeout=60s 2>/dev/null || echo "  No ArgoCD apps found"

# ──────────────────────────────────────────────
#  Phase 2: Observability Stack
#  Uninstall Helm releases BEFORE deleting CRDs
#  and namespaces to avoid finalizer hangs.
# ──────────────────────────────────────────────
echo -e "${YELLOW}[2/${TOTAL_PHASES}] Removing observability stack (monitoring + Loki + Tempo)...${NC}"

helm uninstall tempo     -n monitoring 2>/dev/null && echo "  Uninstalled: tempo"     || echo "  tempo not found"
helm uninstall loki      -n monitoring 2>/dev/null && echo "  Uninstalled: loki"      || echo "  loki not found"
helm uninstall monitoring -n monitoring 2>/dev/null && echo "  Uninstalled: monitoring" || echo "  monitoring not found"

# Delete Prometheus custom resources to clear finalizers
kubectl delete prometheuses     --all -n monitoring 2>/dev/null || true
kubectl delete alertmanagers    --all -n monitoring 2>/dev/null || true
kubectl delete thanosrulers     --all -n monitoring 2>/dev/null || true
kubectl delete servicemonitors  --all -n monitoring 2>/dev/null || true
kubectl delete prometheusrules  --all -n monitoring 2>/dev/null || true

echo "  Removing monitoring CRDs..."
for crd in prometheuses.monitoring.coreos.com \
           alertmanagers.monitoring.coreos.com \
           thanosrulers.monitoring.coreos.com \
           prometheusagents.monitoring.coreos.com \
           scrapeconfigs.monitoring.coreos.com \
           servicemonitors.monitoring.coreos.com \
           podmonitors.monitoring.coreos.com \
           prometheusrules.monitoring.coreos.com \
           probes.monitoring.coreos.com; do
  kubectl delete crd "$crd" 2>/dev/null && echo "    Deleted CRD: $crd" || true
done

kubectl patch namespace monitoring -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete namespace monitoring --timeout=30s 2>/dev/null || echo "  monitoring namespace already gone"
sleep 10

# ──────────────────────────────────────────────
#  Phase 3: Security Stack (ESO + Kyverno)
#  Must run before nimbus namespace deletion.
# ──────────────────────────────────────────────
echo -e "${YELLOW}[3/${TOTAL_PHASES}] Removing security stack (ESO + Kyverno)...${NC}"

# External Secrets Operator — remove CRs before uninstalling operator
kubectl delete externalsecrets   --all -n nimbus 2>/dev/null || true
kubectl delete secretstores      --all -n nimbus 2>/dev/null || true
kubectl delete clustersecretstores --all 2>/dev/null || true
helm uninstall external-secrets -n nimbus 2>/dev/null && echo "  Uninstalled: external-secrets" || echo "  external-secrets not found"

echo "  Removing ESO CRDs..."
kubectl get crds -o name 2>/dev/null | grep external-secrets | xargs -r kubectl delete 2>/dev/null || true

# Kyverno — remove policies before uninstalling operator
kubectl delete clusterpolicies --all 2>/dev/null || true
kubectl delete policies --all -A  2>/dev/null || true
helm uninstall kyverno -n kyverno 2>/dev/null && echo "  Uninstalled: kyverno" || echo "  kyverno not found"

echo "  Removing Kyverno CRDs..."
kubectl get crds -o name 2>/dev/null | grep kyverno | xargs -r kubectl delete 2>/dev/null || true

kubectl patch namespace kyverno -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete namespace kyverno --timeout=30s 2>/dev/null || echo "  kyverno namespace already gone"

# ──────────────────────────────────────────────
#  Phase 4: ArgoCD
# ──────────────────────────────────────────────
echo -e "${YELLOW}[4/${TOTAL_PHASES}] Removing ArgoCD...${NC}"
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --timeout=60s 2>/dev/null || echo "  ArgoCD already removed"
kubectl patch namespace argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete namespace argocd --timeout=30s 2>/dev/null || echo "  argocd namespace already gone"

# ──────────────────────────────────────────────
#  Phase 5: Kafka + Strimzi
#  Finalizers on Kafka CRs block namespace deletion.
# ──────────────────────────────────────────────
echo -e "${YELLOW}[5/${TOTAL_PHASES}] Removing Kafka and Strimzi...${NC}"

for kafka in $(kubectl get kafka -n kafka -o name 2>/dev/null); do
  kubectl patch "$kafka" -n kafka -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done
for pool in $(kubectl get kafkanodepool -n kafka -o name 2>/dev/null); do
  kubectl patch "$pool" -n kafka -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done

kubectl delete kafka          --all -n kafka --timeout=60s 2>/dev/null || echo "  No Kafka CRs found"
kubectl delete kafkanodepool  --all -n kafka --timeout=60s 2>/dev/null || echo "  No KafkaNodePool CRs found"
helm uninstall strimzi -n kafka 2>/dev/null && echo "  Uninstalled: strimzi" || echo "  strimzi not found"

echo "  Removing Strimzi CRDs..."
kubectl get crds -o name 2>/dev/null | grep strimzi | xargs -r kubectl delete 2>/dev/null || true

kubectl patch namespace kafka -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete namespace kafka --timeout=30s 2>/dev/null || echo "  kafka namespace already gone"

# ──────────────────────────────────────────────
#  Phase 6: Nimbus Application Namespace
# ──────────────────────────────────────────────
echo -e "${YELLOW}[6/${TOTAL_PHASES}] Removing Nimbus application resources...${NC}"

for ns in nimbus nimbus-prod; do
  kubectl delete ingress --all -n "$ns" 2>/dev/null || true
done
kubectl delete ingress --all -n monitoring 2>/dev/null || true

echo "  Waiting 60s for ALB deregistration..."
sleep 60

for ns in nimbus nimbus-prod; do
  kubectl delete all     --all -n "$ns" 2>/dev/null || true
  kubectl delete pvc     --all -n "$ns" 2>/dev/null || true
  kubectl delete secrets --all -n "$ns" 2>/dev/null || true
  kubectl patch namespace "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  kubectl delete namespace "$ns" --timeout=30s 2>/dev/null || echo "  $ns namespace already gone"
done

# ──────────────────────────────────────────────
#  Phase 7: Route 53 (first pass)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[7/${TOTAL_PHASES}] Cleaning Route 53 records (first pass)...${NC}"
clean_route53_records

# ──────────────────────────────────────────────
#  Phase 8: VPC Dependency Cleanup
#  ALBs, ENIs, and SGs must be removed before
#  Terraform can delete the VPC.
# ──────────────────────────────────────────────
echo -e "${YELLOW}[8/${TOTAL_PHASES}] Cleaning VPC dependencies (ALBs, ENIs, SGs)...${NC}"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=cloud-native-eks" \
  --query "Vpcs[0].VpcId" --output text --region "$REGION" 2>/dev/null)

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "  Found VPC: $VPC_ID"

  for ALB_ARN in $(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
    echo "  Deleting ALB: $ALB_ARN"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION" 2>/dev/null || true
  done
  sleep 30

  for ENI_ID in $(aws ec2 describe-network-interfaces \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "NetworkInterfaces[].NetworkInterfaceId" --output text --region "$REGION" 2>/dev/null); do
    echo "  Deleting ENI: $ENI_ID"
    aws ec2 delete-network-interface --network-interface-id "$ENI_ID" --region "$REGION" 2>/dev/null || true
  done

  for SG_ID in $(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text --region "$REGION" 2>/dev/null); do
    echo "  Deleting SG: $SG_ID"
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
  done

  # Clean orphan EBS volumes (Kafka PVCs may leave volumes in 'available' state)
  for VOL_ID in $(aws ec2 describe-volumes \
    --filters "Name=status,Values=available" "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
    --query "Volumes[].VolumeId" --output text --region "$REGION" 2>/dev/null); do
    echo "  Deleting orphan EBS volume: $VOL_ID"
    aws ec2 delete-volume --volume-id "$VOL_ID" --region "$REGION" 2>/dev/null || true
  done
else
  echo "  No project VPC found — skipping"
fi

# ──────────────────────────────────────────────
#  Phase 9: EKS Infrastructure (Terraform)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[9/${TOTAL_PHASES}] Destroying EKS infrastructure via Terraform...${NC}"

EKS_DIR=""
if [ -d "EKS-Terraform" ]; then EKS_DIR="EKS-Terraform"
elif [ -d "../EKS-Terraform" ]; then EKS_DIR="../EKS-Terraform"
fi

if [ -n "$EKS_DIR" ]; then
  cd "$EKS_DIR"

  # Remove resources already cleaned manually (prevents Terraform timeout)
  terraform state rm kubernetes_namespace.monitoring   2>/dev/null || true
  terraform state rm kubernetes_namespace.argocd       2>/dev/null || true
  terraform state rm kubernetes_namespace.kafka        2>/dev/null || true
  terraform state rm kubernetes_namespace.three_tier   2>/dev/null || true
  terraform state rm helm_release.monitoring           2>/dev/null || true
  terraform state rm helm_release.loki                 2>/dev/null || true
  terraform state rm helm_release.tempo                2>/dev/null || true
  terraform state rm helm_release.strimzi              2>/dev/null || true
  terraform state rm helm_release.eso                  2>/dev/null || true
  terraform state rm helm_release.kyverno              2>/dev/null || true

  terraform init -input=false 2>/dev/null

  # Second Route 53 pass — ExternalDNS may have recreated records
  echo "  Cleaning Route 53 records (second pass before Terraform destroy)..."
  clean_route53_records

  terraform destroy -auto-approve -var-file="nimbus.tfvars" || echo "  Terraform destroy had errors — check console"
  cd - > /dev/null
else
  echo "  EKS-Terraform directory not found — skipping"
fi

# ──────────────────────────────────────────────
#  Phase 10: ECR Repositories
#  Delete all repos — Nimbus + legacy three-tier.
# ──────────────────────────────────────────────
echo -e "${YELLOW}[10/${TOTAL_PHASES}] Deleting ECR repositories...${NC}"

for svc in auth-service catalog-service cart-service order-service notification-service; do
  aws ecr delete-repository --repository-name "nimbus/$svc" \
    --region "$REGION" --force 2>/dev/null \
    && echo "  Deleted: nimbus/$svc" || echo "  nimbus/$svc already gone"
done

for repo in frontend backend; do
  aws ecr delete-repository --repository-name "$repo" \
    --region "$REGION" --force 2>/dev/null \
    && echo "  Deleted: $repo" || echo "  $repo already gone"
done

# ──────────────────────────────────────────────
#  Phase 11: Jenkins Server + Orphan Cleanup
#  + Secrets Manager secrets
# ──────────────────────────────────────────────
echo -e "${YELLOW}[11/${TOTAL_PHASES}] Destroying Jenkins server and cleaning orphan resources...${NC}"

JENKINS_DIR=""
if [ -d "Jenkins-Server-TF" ]; then JENKINS_DIR="Jenkins-Server-TF"
elif [ -d "../Jenkins-Server-TF" ]; then JENKINS_DIR="../Jenkins-Server-TF"
fi

if [ -n "$JENKINS_DIR" ]; then
  cd "$JENKINS_DIR"
  terraform init -input=false 2>/dev/null
  terraform destroy -auto-approve || echo "  Jenkins Terraform destroy had errors"
  cd - > /dev/null
fi

# Orphan Jenkins IAM resources (Terraform may miss if state is stale)
echo "  Cleaning orphan Jenkins IAM resources..."
aws iam remove-role-from-instance-profile \
  --instance-profile-name jenkins-cloud-native-profile \
  --role-name jenkins-cloud-native-role 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name jenkins-cloud-native-profile 2>/dev/null || true
for ARN in $(aws iam list-attached-role-policies \
    --role-name jenkins-cloud-native-role \
    --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name jenkins-cloud-native-role --policy-arn "$ARN" 2>/dev/null || true
done
for NAME in $(aws iam list-role-policies \
    --role-name jenkins-cloud-native-role \
    --query "PolicyNames[]" --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name jenkins-cloud-native-role --policy-name "$NAME" 2>/dev/null || true
done
aws iam delete-role --role-name jenkins-cloud-native-role 2>/dev/null || true
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=jenkins-cloud-native-sg" \
  --query "SecurityGroups[0].GroupId" --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
  aws ec2 delete-security-group --group-id "$SG_ID" --region "$REGION" 2>/dev/null || true
  echo "  Deleted Jenkins SG: $SG_ID"
fi

# Delete Secrets Manager secrets (prevent hidden ongoing cost)
echo "  Deleting Secrets Manager secrets..."
for secret in \
    "nimbus-cluster/nimbus-secrets" \
    "nimbus-cluster/nimbus-catalog-secrets" \
    "${CLUSTER_NAME}/rds/master-password"; do
  aws secretsmanager delete-secret \
    --secret-id "$secret" \
    --force-delete-without-recovery \
    --region "$REGION" 2>/dev/null \
    && echo "  Deleted secret: $secret" || echo "  $secret not found"
done

# ──────────────────────────────────────────────
#  Final Verification — scan for all billable
#  resource types that could cause hidden costs
# ──────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Running final verification scan...${NC}"
echo ""

ALL_CLEAN=true

INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text --region "$REGION" 2>/dev/null)
CLUSTERS=$(aws eks list-clusters \
  --query "clusters" --output text --region "$REGION" 2>/dev/null)
VPCS=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=false" \
  --query "Vpcs[].VpcId" --output text --region "$REGION" 2>/dev/null)
ELBS=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[].LoadBalancerArn" --output text --region "$REGION" 2>/dev/null)
NATS=$(aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[].NatGatewayId" --output text --region "$REGION" 2>/dev/null)
EIPS=$(aws ec2 describe-addresses \
  --query "Addresses[].AllocationId" --output text --region "$REGION" 2>/dev/null)
RDS=$(aws rds describe-db-instances \
  --query "DBInstances[].DBInstanceIdentifier" --output text --region "$REGION" 2>/dev/null)
REDIS=$(aws elasticache describe-cache-clusters \
  --query "CacheClusters[].CacheClusterId" --output text --region "$REGION" 2>/dev/null)
EBS_ORPHANS=$(aws ec2 describe-volumes \
  --filters "Name=status,Values=available" \
  --query "Volumes[].VolumeId" --output text --region "$REGION" 2>/dev/null)
ECR_REPOS=$(aws ecr describe-repositories \
  --query "repositories[].repositoryName" --output text --region "$REGION" 2>/dev/null)
SM_SECRETS=$(aws secretsmanager list-secrets \
  --filters Key=name,Values=nimbus \
  --query "SecretList[].Name" --output text --region "$REGION" 2>/dev/null)

check() {
  local label="$1" value="$2"
  if [ -n "$value" ]; then
    echo -e "  ${RED}⚠  $label: $value${NC}"
    ALL_CLEAN=false
  else
    echo -e "  ${GREEN}✅ No $label${NC}"
  fi
}

check "Running/stopped EC2 instances" "$INSTANCES"
check "EKS clusters"                  "$CLUSTERS"
check "Non-default VPCs"              "$VPCS"
check "Load balancers"                "$ELBS"
check "NAT gateways"                  "$NATS"
check "Elastic IPs"                   "$EIPS"
check "RDS instances"                 "$RDS"
check "ElastiCache clusters"          "$REDIS"
check "Orphan EBS volumes"            "$EBS_ORPHANS"
check "ECR repositories"              "$ECR_REPOS"
check "Secrets Manager (nimbus/*)"    "$SM_SECRETS"

echo ""
if [ "$ALL_CLEAN" = true ]; then
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
  echo "║      DESTROY COMPLETE — ALL CLEAN                ║"
  echo "║      No billable resources detected.             ║"
  echo "╚══════════════════════════════════════════════════╝${NC}"
else
  echo -e "${RED}╔══════════════════════════════════════════════════╗"
  echo "║   SOME RESOURCES REMAIN — CHECK ITEMS ABOVE     ║"
  echo "║   Delete them manually to avoid ongoing costs.  ║"
  echo "╚══════════════════════════════════════════════════╝${NC}"
fi

echo ""
echo -e "${YELLOW}S3 bucket and DynamoDB table are intentionally preserved${NC}"
echo "  (they cost nearly nothing and allow re-deployment without re-bootstrapping)"
echo ""
echo "To delete them permanently when the project is fully done:"
echo "  aws s3 rm s3://ibrahim-cloud-native-tf-state --recursive"
echo "  aws s3api delete-bucket --bucket ibrahim-cloud-native-tf-state"
echo "  aws dynamodb delete-table --table-name ibrahim-cloud-native-tf-lock --region $REGION"
