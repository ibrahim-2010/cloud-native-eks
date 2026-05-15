#!/bin/bash
set -uo pipefail
# =============================================================================
#  NimbusRetail — Full Stack Destroy Script
#
#  Phases (in order):
#    1.  ArgoCD applications (finalizers cleared first)
#    2.  Observability stack (Helm uninstall + CRDs)
#    3.  Security stack (ESO + Kyverno)
#    4.  ArgoCD namespace
#    5.  Kafka + Strimzi
#    6.  Application namespaces + ALL ingresses (triggers ALB cleanup)
#    7.  Route 53 — first pass (ExternalDNS may recreate between phases)
#    8.  ALBs + target groups + EBS volumes  (VPC deps — NO VPC delete yet)
#    9.  EKS infrastructure via Terraform
#    9b. AWS CLI fallback — EKS, RDS, ElastiCache, subnet groups, NAT, EIP, VPC
#    10. ECR repositories
#    11. Jenkins server + IAM + Secrets Manager
#    Final: verification scan
#
#  Usage: bash destroy.sh [--skip-confirmation]
#  Run from the repo root with kubectl + AWS CLI configured.
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
#  Helper: clean_route53
#  Deletes all non-NS/SOA records from the hosted zone.
#  Uses a temp file (not stdin) — stdin piping is unreliable.
#  Falls back to one-by-one deletion if batch fails.
# ══════════════════════════════════════════════════════════════
clean_route53() {
  local ZONE_ID
  ZONE_ID=$(aws route53 list-hosted-zones \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id" \
    --output text 2>/dev/null | sed 's|/hostedzone/||' | head -1)

  if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
    echo "  Route 53: no hosted zone for $DOMAIN — skipping"
    return 0
  fi
  echo "  Route 53 zone: $ZONE_ID"

  local RECORDS
  RECORDS=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Type!='NS' && Type!='SOA']" \
    --output json 2>/dev/null || echo "[]")

  local COUNT
  COUNT=$(python3 -c "import json,sys; print(len(json.load(sys.stdin)))" \
    <<< "$RECORDS" 2>/dev/null || echo "0")

  if [ "$COUNT" = "0" ]; then
    echo "  Route 53: no records to delete"
    return 0
  fi
  echo "  Route 53: deleting $COUNT records..."

  # Write change batch to a temp file — avoids stdin pipe failures
  local BATCH_FILE
  BATCH_FILE=$(mktemp /tmp/r53-batch-XXXXXX.json)

  python3 - <<PYEOF > "$BATCH_FILE" 2>/dev/null
import json, sys
records = json.loads('''${RECORDS}''')
changes = [{"Action": "DELETE", "ResourceRecordSet": r} for r in records]
print(json.dumps({"Changes": changes}))
PYEOF

  if aws route53 change-resource-record-sets \
      --hosted-zone-id "$ZONE_ID" \
      --change-batch "file://$BATCH_FILE" 2>/dev/null; then
    echo "  Route 53: all records deleted (batch)"
  else
    echo "  Route 53: batch failed — deleting one by one..."
    python3 - <<PYEOF 2>/dev/null
import json, subprocess, tempfile, os

records = json.loads('''${RECORDS}''')
for r in records:
    name = r.get("Name", "?")
    rtype = r.get("Type", "?")
    batch = json.dumps({"Changes": [{"Action": "DELETE", "ResourceRecordSet": r}]})
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        f.write(batch)
        fname = f.name
    result = subprocess.run(
        ["aws", "route53", "change-resource-record-sets",
         "--hosted-zone-id", "${ZONE_ID}",
         "--change-batch", f"file://{fname}"],
        capture_output=True, text=True
    )
    os.unlink(fname)
    if result.returncode == 0:
        print(f"    Deleted: {name} {rtype}")
    else:
        err = result.stderr.strip().replace("\n", " ")
        print(f"    Skipped: {name} {rtype} — {err}")
PYEOF
  fi

  rm -f "$BATCH_FILE"
  sleep 5
}

# ══════════════════════════════════════════════════════════════
#  Helper: clean_vpc
#  Full ordered teardown — must run AFTER RDS + ElastiCache
#  are deleted (their ENIs/subnet groups block VPC deletion).
#  Order: endpoints → ENIs → SG rules → SGs → subnets →
#         route tables → IGW → DHCP → VPC
# ══════════════════════════════════════════════════════════════
clean_vpc() {
  local VPC="$1"
  [ -z "$VPC" ] || [ "$VPC" = "None" ] && return 0
  echo "  Cleaning VPC: $VPC"

  # 1. VPC Endpoints (Interface + Gateway)
  local ENDPOINTS
  ENDPOINTS=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC" \
    --query "VpcEndpoints[?State!='deleted'].VpcEndpointId" \
    --output text --region "$REGION" 2>/dev/null)
  for EP in $ENDPOINTS; do
    echo "    Deleting endpoint: $EP"
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$EP" \
      --region "$REGION" 2>/dev/null || true
  done
  [ -n "$ENDPOINTS" ] && sleep 10

  # 2. Detach + delete network interfaces
  for ENI in $(aws ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=$VPC" \
      --query "NetworkInterfaces[].NetworkInterfaceId" \
      --output text --region "$REGION" 2>/dev/null); do
    local ATTACH
    ATTACH=$(aws ec2 describe-network-interfaces \
      --network-interface-ids "$ENI" \
      --query "NetworkInterfaces[0].Attachment.AttachmentId" \
      --output text --region "$REGION" 2>/dev/null || echo "")
    if [ -n "$ATTACH" ] && [ "$ATTACH" != "None" ]; then
      aws ec2 detach-network-interface --attachment-id "$ATTACH" \
        --force --region "$REGION" 2>/dev/null || true
      sleep 5
    fi
    echo "    Deleting ENI: $ENI"
    aws ec2 delete-network-interface --network-interface-id "$ENI" \
      --region "$REGION" 2>/dev/null || true
  done

  # 3. Clear SG rules (cross-references prevent deletion)
  # Includes k8s-elb-* SGs left behind by classic ELBs after deletion
  local SGS
  SGS=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text --region "$REGION" 2>/dev/null)
  for SG in $SGS; do
    local INGRESS EGRESS
    INGRESS=$(aws ec2 describe-security-groups --group-ids "$SG" \
      --query "SecurityGroups[0].IpPermissions" \
      --output json --region "$REGION" 2>/dev/null || echo "[]")
    EGRESS=$(aws ec2 describe-security-groups --group-ids "$SG" \
      --query "SecurityGroups[0].IpPermissionsEgress" \
      --output json --region "$REGION" 2>/dev/null || echo "[]")
    [ "$INGRESS" != "[]" ] && [ -n "$INGRESS" ] && \
      aws ec2 revoke-security-group-ingress --group-id "$SG" \
        --ip-permissions "$INGRESS" --region "$REGION" 2>/dev/null || true
    [ "$EGRESS" != "[]" ] && [ -n "$EGRESS" ] && \
      aws ec2 revoke-security-group-egress --group-id "$SG" \
        --ip-permissions "$EGRESS" --region "$REGION" 2>/dev/null || true
  done

  # 4. Delete non-default security groups
  for SG in $SGS; do
    echo "    Deleting SG: $SG"
    aws ec2 delete-security-group --group-id "$SG" \
      --region "$REGION" 2>/dev/null || true
  done

  # 5. Delete subnets
  for SUBNET in $(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$VPC" \
      --query "Subnets[].SubnetId" \
      --output text --region "$REGION" 2>/dev/null); do
    echo "    Deleting subnet: $SUBNET"
    aws ec2 delete-subnet --subnet-id "$SUBNET" \
      --region "$REGION" 2>/dev/null || true
  done

  # 6. Delete non-main route tables
  for RT in $(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$VPC" \
      --query "RouteTables[?length(Associations[?Main==\`false\`])>\`0\` || length(Associations)==\`0\`].RouteTableId" \
      --output text --region "$REGION" 2>/dev/null); do
    echo "    Deleting route table: $RT"
    aws ec2 delete-route-table --route-table-id "$RT" \
      --region "$REGION" 2>/dev/null || true
  done

  # 7. Detach + delete internet gateway
  for IGW in $(aws ec2 describe-internet-gateways \
      --filters "Name=attachment.vpc-id,Values=$VPC" \
      --query "InternetGateways[].InternetGatewayId" \
      --output text --region "$REGION" 2>/dev/null); do
    echo "    Deleting IGW: $IGW"
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" \
      --vpc-id "$VPC" --region "$REGION" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW" \
      --region "$REGION" 2>/dev/null || true
  done

  # 8. Disassociate and delete non-default DHCP option sets
  local DHCP
  DHCP=$(aws ec2 describe-vpcs --vpc-ids "$VPC" \
    --query "Vpcs[0].DhcpOptionsId" \
    --output text --region "$REGION" 2>/dev/null || echo "")
  if [ -n "$DHCP" ] && [ "$DHCP" != "None" ] && [ "$DHCP" != "default" ]; then
    local DEFAULT_DHCP
    DEFAULT_DHCP=$(aws ec2 describe-dhcp-options \
      --filters "Name=key,Values=domain-name" \
      --query "DhcpOptions[?DhcpConfigurations[?Key=='domain-name']].DhcpOptionsId" \
      --output text --region "$REGION" 2>/dev/null | head -1)
    if [ -n "$DEFAULT_DHCP" ] && [ "$DEFAULT_DHCP" != "$DHCP" ]; then
      aws ec2 associate-dhcp-options --dhcp-options-id default \
        --vpc-id "$VPC" --region "$REGION" 2>/dev/null || true
      aws ec2 delete-dhcp-options --dhcp-options-id "$DHCP" \
        --region "$REGION" 2>/dev/null || true
    fi
  fi

  # 9. Delete VPC
  if aws ec2 delete-vpc --vpc-id "$VPC" --region "$REGION" 2>/dev/null; then
    echo "  Deleted VPC: $VPC"
  else
    echo -e "  ${RED}VPC $VPC still blocked — remaining dependencies:${NC}"
    aws ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=$VPC" \
      --query "NetworkInterfaces[*].[NetworkInterfaceId,Status,Description]" \
      --output table --region "$REGION" 2>/dev/null || true
  fi
}

# ──────────────────────────────────────────────
#  Phase 1: ArgoCD Applications
# ──────────────────────────────────────────────
echo -e "${YELLOW}[1/${TOTAL_PHASES}] Removing ArgoCD applications...${NC}"
for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do
  kubectl patch "$app" -n argocd \
    -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done
kubectl delete applications --all -n argocd --timeout=60s 2>/dev/null \
  || echo "  No ArgoCD apps found"

# ──────────────────────────────────────────────
#  Phase 2: Observability Stack
# ──────────────────────────────────────────────
echo -e "${YELLOW}[2/${TOTAL_PHASES}] Removing observability stack...${NC}"

helm uninstall tempo      -n monitoring 2>/dev/null && echo "  Uninstalled: tempo"      || echo "  tempo not found"
helm uninstall loki       -n monitoring 2>/dev/null && echo "  Uninstalled: loki"       || echo "  loki not found"
helm uninstall monitoring -n monitoring 2>/dev/null && echo "  Uninstalled: monitoring" || echo "  monitoring not found"

kubectl delete prometheuses     --all -n monitoring 2>/dev/null || true
kubectl delete alertmanagers    --all -n monitoring 2>/dev/null || true
kubectl delete thanosrulers     --all -n monitoring 2>/dev/null || true
kubectl delete servicemonitors  --all -n monitoring 2>/dev/null || true
kubectl delete prometheusrules  --all -n monitoring 2>/dev/null || true

for crd in prometheuses.monitoring.coreos.com \
           alertmanagers.monitoring.coreos.com \
           thanosrulers.monitoring.coreos.com \
           prometheusagents.monitoring.coreos.com \
           scrapeconfigs.monitoring.coreos.com \
           servicemonitors.monitoring.coreos.com \
           podmonitors.monitoring.coreos.com \
           prometheusrules.monitoring.coreos.com \
           probes.monitoring.coreos.com; do
  kubectl delete crd "$crd" 2>/dev/null || true
done

kubectl patch namespace monitoring \
  -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete namespace monitoring --timeout=30s 2>/dev/null \
  || echo "  monitoring already gone"
sleep 10

# ──────────────────────────────────────────────
#  Phase 3: Security Stack (ESO + Kyverno)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[3/${TOTAL_PHASES}] Removing security stack...${NC}"

kubectl delete externalsecrets     --all -n nimbus 2>/dev/null || true
kubectl delete secretstores        --all -n nimbus 2>/dev/null || true
kubectl delete clustersecretstores --all           2>/dev/null || true
helm uninstall external-secrets -n nimbus 2>/dev/null \
  && echo "  Uninstalled: external-secrets" || echo "  external-secrets not found"
kubectl get crds -o name 2>/dev/null | grep external-secrets \
  | xargs -r kubectl delete 2>/dev/null || true

kubectl delete clusterpolicies --all    2>/dev/null || true
kubectl delete policies        --all -A 2>/dev/null || true
helm uninstall kyverno -n kyverno 2>/dev/null \
  && echo "  Uninstalled: kyverno" || echo "  kyverno not found"
kubectl get crds -o name 2>/dev/null | grep kyverno \
  | xargs -r kubectl delete 2>/dev/null || true

kubectl patch namespace kyverno \
  -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete namespace kyverno --timeout=30s 2>/dev/null \
  || echo "  kyverno already gone"

# ──────────────────────────────────────────────
#  Phase 4: ArgoCD
# ──────────────────────────────────────────────
echo -e "${YELLOW}[4/${TOTAL_PHASES}] Removing ArgoCD...${NC}"
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --timeout=60s 2>/dev/null || echo "  ArgoCD already removed"
kubectl patch namespace argocd \
  -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete namespace argocd --timeout=30s 2>/dev/null \
  || echo "  argocd already gone"

# ──────────────────────────────────────────────
#  Phase 5: Kafka + Strimzi
# ──────────────────────────────────────────────
echo -e "${YELLOW}[5/${TOTAL_PHASES}] Removing Kafka and Strimzi...${NC}"

for kafka in $(kubectl get kafka -n kafka -o name 2>/dev/null); do
  kubectl patch "$kafka" -n kafka \
    -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done
for pool in $(kubectl get kafkanodepool -n kafka -o name 2>/dev/null); do
  kubectl patch "$pool" -n kafka \
    -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done

kubectl delete kafka         --all -n kafka --timeout=60s 2>/dev/null \
  || echo "  No Kafka CRs found"
kubectl delete kafkanodepool --all -n kafka --timeout=60s 2>/dev/null \
  || echo "  No KafkaNodePool CRs found"
helm uninstall strimzi -n kafka 2>/dev/null \
  && echo "  Uninstalled: strimzi" || echo "  strimzi not found"
kubectl get crds -o name 2>/dev/null | grep strimzi \
  | xargs -r kubectl delete 2>/dev/null || true

kubectl patch namespace kafka \
  -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete namespace kafka --timeout=30s 2>/dev/null \
  || echo "  kafka already gone"

# ──────────────────────────────────────────────
#  Phase 6: All ingresses + application namespaces
#  Delete ingresses FIRST — signals ALB controller
#  to deregister and delete ALBs before we wait.
# ──────────────────────────────────────────────
echo -e "${YELLOW}[6/${TOTAL_PHASES}] Removing ingresses and application namespaces...${NC}"

echo "  Deleting all ingresses across all namespaces..."
kubectl delete ingress -A --all 2>/dev/null || true

echo "  Waiting 90s for ALB/NLB deregistration..."
sleep 90

for ns in nimbus nimbus-prod; do
  kubectl delete all     --all -n "$ns" 2>/dev/null || true
  kubectl delete pvc     --all -n "$ns" 2>/dev/null || true
  kubectl delete secrets --all -n "$ns" 2>/dev/null || true
  kubectl patch namespace "$ns" \
    -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  kubectl delete namespace "$ns" --timeout=30s 2>/dev/null \
    || echo "  $ns already gone"
done

# ──────────────────────────────────────────────
#  Phase 7: Route 53 — first pass
# ──────────────────────────────────────────────
echo -e "${YELLOW}[7/${TOTAL_PHASES}] Cleaning Route 53 (first pass)...${NC}"
clean_route53

# ──────────────────────────────────────────────
#  Phase 8: ALBs + target groups + EBS volumes
#  Clean load-balancer dependencies before
#  Terraform destroy. Do NOT delete VPC here —
#  RDS/ElastiCache subnet groups still exist.
# ──────────────────────────────────────────────
echo -e "${YELLOW}[8/${TOTAL_PHASES}] Cleaning ALBs, target groups, EBS volumes...${NC}"

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=false" \
  --query "Vpcs[0].VpcId" --output text --region "$REGION" 2>/dev/null)

if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  echo "  VPC: $VPC_ID"

  # Classic ELBs (created by K8s in-tree cloud provider for type:LoadBalancer services)
  for CLB in $(aws elb describe-load-balancers --region "$REGION" \
      --query "LoadBalancerDescriptions[].LoadBalancerName" \
      --output text 2>/dev/null); do
    echo "  Deleting classic ELB: $CLB"
    aws elb delete-load-balancer --load-balancer-name "$CLB" \
      --region "$REGION" 2>/dev/null || true
  done

  # ALBs and NLBs (created by AWS Load Balancer Controller)
  for ALB_ARN in $(aws elbv2 describe-load-balancers --region "$REGION" \
      --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
      --output text 2>/dev/null); do
    echo "  Deleting ALB/NLB: $ALB_ARN"
    aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" \
      --region "$REGION" 2>/dev/null || true
  done
  sleep 60

  for TG_ARN in $(aws elbv2 describe-target-groups --region "$REGION" \
      --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" \
      --output text 2>/dev/null); do
    echo "  Deleting target group: $TG_ARN"
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" \
      --region "$REGION" 2>/dev/null || true
  done

  for VOL in $(aws ec2 describe-volumes --region "$REGION" \
      --filters "Name=status,Values=available" \
      --query "Volumes[].VolumeId" --output text 2>/dev/null); do
    echo "  Deleting EBS volume: $VOL"
    aws ec2 delete-volume --volume-id "$VOL" --region "$REGION" 2>/dev/null || true
  done
else
  echo "  No non-default VPC found"
fi

# ──────────────────────────────────────────────
#  Phase 9: EKS Infrastructure (Terraform)
# ──────────────────────────────────────────────
echo -e "${YELLOW}[9/${TOTAL_PHASES}] Destroying EKS infrastructure via Terraform...${NC}"

EKS_DIR=""
if   [ -d "EKS-Terraform" ];    then EKS_DIR="EKS-Terraform"
elif [ -d "../EKS-Terraform" ]; then EKS_DIR="../EKS-Terraform"
fi

if [ -n "$EKS_DIR" ]; then
  cd "$EKS_DIR"
  terraform state rm kubernetes_namespace.monitoring 2>/dev/null || true
  terraform state rm kubernetes_namespace.argocd     2>/dev/null || true
  terraform state rm kubernetes_namespace.kafka      2>/dev/null || true
  terraform state rm kubernetes_namespace.nimbus     2>/dev/null || true
  terraform state rm helm_release.monitoring         2>/dev/null || true
  terraform state rm helm_release.loki               2>/dev/null || true
  terraform state rm helm_release.tempo              2>/dev/null || true
  terraform state rm helm_release.strimzi            2>/dev/null || true
  terraform state rm helm_release.eso                2>/dev/null || true
  terraform state rm helm_release.kyverno            2>/dev/null || true

  terraform init -input=false 2>/dev/null

  echo "  Route 53 second pass (ExternalDNS may have recreated records)..."
  clean_route53

  terraform destroy -auto-approve -var-file="nimbus.tfvars" \
    || echo "  Terraform destroy had errors — AWS CLI fallback will clean remainder"
  cd - > /dev/null
else
  echo "  EKS-Terraform directory not found — skipping Terraform"
fi

# ──────────────────────────────────────────────
#  Phase 9b: AWS CLI Fallback
#  Catches anything Terraform failed to delete.
#  Order matters: EKS → RDS → ElastiCache →
#  subnet groups → NAT → EIP → VPC
# ──────────────────────────────────────────────
echo -e "${YELLOW}[9b] AWS CLI fallback cleanup...${NC}"

# EKS node groups + cluster
for CLUSTER in $(aws eks list-clusters --region "$REGION" \
    --query "clusters" --output text 2>/dev/null); do
  for NG in $(aws eks list-nodegroups --cluster-name "$CLUSTER" \
      --region "$REGION" --query "nodegroups" --output text 2>/dev/null); do
    echo "  Deleting node group: $NG"
    aws eks delete-nodegroup --cluster-name "$CLUSTER" \
      --nodegroup-name "$NG" --region "$REGION" 2>/dev/null || true
    aws eks wait nodegroup-deleted --cluster-name "$CLUSTER" \
      --nodegroup-name "$NG" --region "$REGION" 2>/dev/null || true
  done
  echo "  Deleting EKS cluster: $CLUSTER"
  aws eks delete-cluster --name "$CLUSTER" --region "$REGION" 2>/dev/null || true
  aws eks wait cluster-deleted --name "$CLUSTER" --region "$REGION" 2>/dev/null || true
done

# RDS instances
for DB in $(aws rds describe-db-instances --region "$REGION" \
    --query "DBInstances[].DBInstanceIdentifier" --output text 2>/dev/null); do
  echo "  Deleting RDS instance: $DB"
  aws rds delete-db-instance --db-instance-identifier "$DB" \
    --skip-final-snapshot --region "$REGION" 2>/dev/null || true
done

# ElastiCache replication groups + clusters
for RG in $(aws elasticache describe-replication-groups --region "$REGION" \
    --query "ReplicationGroups[].ReplicationGroupId" --output text 2>/dev/null); do
  echo "  Deleting ElastiCache replication group: $RG"
  aws elasticache delete-replication-group --replication-group-id "$RG" \
    --region "$REGION" 2>/dev/null || true
done
for CC in $(aws elasticache describe-cache-clusters --region "$REGION" \
    --query "CacheClusters[].CacheClusterId" --output text 2>/dev/null); do
  echo "  Deleting ElastiCache cluster: $CC"
  aws elasticache delete-cache-cluster --cache-cluster-id "$CC" \
    --region "$REGION" 2>/dev/null || true
done

# Wait for RDS to finish deleting
echo "  Waiting for RDS deletion to complete..."
for DB in $(aws rds describe-db-instances --region "$REGION" \
    --query "DBInstances[].DBInstanceIdentifier" --output text 2>/dev/null); do
  echo "  Waiting on RDS: $DB"
  aws rds wait db-instance-deleted --db-instance-identifier "$DB" \
    --region "$REGION" 2>/dev/null || true
done

# Wait for ElastiCache to finish deleting (no AWS waiter — poll)
echo "  Waiting for ElastiCache deletion to complete (~3 min)..."
for i in $(seq 1 18); do
  CC_COUNT=$(aws elasticache describe-cache-clusters --region "$REGION" \
    --query "length(CacheClusters)" --output text 2>/dev/null || echo "0")
  [ "$CC_COUNT" = "0" ] && echo "  ElastiCache deleted" && break
  echo "  Still deleting ElastiCache ($i/18)..."
  sleep 10
done

# Delete RDS subnet groups (block VPC deletion if left behind)
echo "  Deleting RDS subnet groups..."
for SG in $(aws rds describe-db-subnet-groups --region "$REGION" \
    --query "DBSubnetGroups[].DBSubnetGroupName" --output text 2>/dev/null); do
  [ "$SG" = "default" ] && continue
  echo "  Deleting RDS subnet group: $SG"
  aws rds delete-db-subnet-group --db-subnet-group-name "$SG" \
    --region "$REGION" 2>/dev/null || true
done

# Delete ElastiCache subnet groups (block VPC deletion if left behind)
echo "  Deleting ElastiCache subnet groups..."
for SG in $(aws elasticache describe-cache-subnet-groups --region "$REGION" \
    --query "CacheSubnetGroups[].CacheSubnetGroupName" --output text 2>/dev/null); do
  [ "$SG" = "default" ] && continue
  echo "  Deleting ElastiCache subnet group: $SG"
  aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$SG" \
    --region "$REGION" 2>/dev/null || true
done

# Remaining EBS volumes
for VOL in $(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=status,Values=available" \
    --query "Volumes[].VolumeId" --output text 2>/dev/null); do
  echo "  Deleting EBS volume: $VOL"
  aws ec2 delete-volume --volume-id "$VOL" --region "$REGION" 2>/dev/null || true
done

# NAT Gateways
for NAT in $(aws ec2 describe-nat-gateways \
    --filter "Name=state,Values=available,pending" --region "$REGION" \
    --query "NatGateways[].NatGatewayId" --output text 2>/dev/null); do
  echo "  Deleting NAT Gateway: $NAT"
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT" \
    --region "$REGION" 2>/dev/null || true
done
# Poll until all NAT Gateways are deleted before releasing EIPs
echo "  Waiting for NAT Gateway deletion..."
for i in $(seq 1 24); do
  NAT_COUNT=$(aws ec2 describe-nat-gateways \
    --filter "Name=state,Values=available,pending,deleting" \
    --region "$REGION" \
    --query "length(NatGateways)" --output text 2>/dev/null || echo "0")
  [ "$NAT_COUNT" = "0" ] && echo "  NAT Gateways deleted" && break
  echo "  Waiting on NAT ($i/24)..."
  sleep 10
done

# Elastic IPs
for EIP in $(aws ec2 describe-addresses \
    --query "Addresses[].AllocationId" --output text --region "$REGION" 2>/dev/null); do
  echo "  Releasing EIP: $EIP"
  aws ec2 release-address --allocation-id "$EIP" \
    --region "$REGION" 2>/dev/null || true
done

# Final Route 53 pass — ExternalDNS may have written new records
echo "  Route 53 final pass..."
clean_route53

# Classic ELBs — created by K8s in-tree provider (type:LoadBalancer on services)
echo "  Deleting classic ELBs (aws elb)..."
for CLB in $(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[].LoadBalancerName" \
    --output text 2>/dev/null); do
  echo "  Deleting classic ELB: $CLB"
  aws elb delete-load-balancer --load-balancer-name "$CLB" \
    --region "$REGION" 2>/dev/null || true
done
echo "  Waiting 60s for classic ELB ENIs to release..."
sleep 60

# VPC full teardown — safe now that RDS/ElastiCache/NAT/EIP are gone
for VPC in $(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=isDefault,Values=false" \
    --query "Vpcs[].VpcId" --output text 2>/dev/null); do
  clean_vpc "$VPC"
done

# ──────────────────────────────────────────────
#  Phase 10: ECR Repositories
# ──────────────────────────────────────────────
echo -e "${YELLOW}[10/${TOTAL_PHASES}] Deleting ECR repositories...${NC}"

for svc in auth-service catalog-service cart-service order-service notification-service; do
  aws ecr delete-repository --repository-name "nimbus/$svc" \
    --region "$REGION" --force 2>/dev/null \
    && echo "  Deleted: nimbus/$svc" || echo "  nimbus/$svc already gone"
done

# ──────────────────────────────────────────────
#  Phase 11: Jenkins Server + IAM + Secrets Manager
# ──────────────────────────────────────────────
echo -e "${YELLOW}[11/${TOTAL_PHASES}] Destroying Jenkins server and cleaning orphan resources...${NC}"

JENKINS_DIR=""
if   [ -d "Jenkins-Server-TF" ];    then JENKINS_DIR="Jenkins-Server-TF"
elif [ -d "../Jenkins-Server-TF" ]; then JENKINS_DIR="../Jenkins-Server-TF"
fi

if [ -n "$JENKINS_DIR" ]; then
  cd "$JENKINS_DIR"
  terraform init -input=false 2>/dev/null
  terraform destroy -auto-approve || echo "  Jenkins Terraform destroy had errors"
  cd - > /dev/null
fi

# Orphan Jenkins IAM resources
echo "  Cleaning orphan Jenkins IAM resources..."
aws iam remove-role-from-instance-profile \
  --instance-profile-name jenkins-cloud-native-profile \
  --role-name jenkins-cloud-native-role 2>/dev/null || true
aws iam delete-instance-profile \
  --instance-profile-name jenkins-cloud-native-profile 2>/dev/null || true
for ARN in $(aws iam list-attached-role-policies \
    --role-name jenkins-cloud-native-role \
    --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null); do
  aws iam detach-role-policy \
    --role-name jenkins-cloud-native-role --policy-arn "$ARN" 2>/dev/null || true
done
for NAME in $(aws iam list-role-policies \
    --role-name jenkins-cloud-native-role \
    --query "PolicyNames[]" --output text 2>/dev/null); do
  aws iam delete-role-policy \
    --role-name jenkins-cloud-native-role --policy-name "$NAME" 2>/dev/null || true
done
aws iam delete-role --role-name jenkins-cloud-native-role 2>/dev/null || true

# Delete Secrets Manager secrets
echo "  Deleting Secrets Manager secrets..."
for secret in \
    "nimbus-cluster/nimbus-secrets" \
    "nimbus-cluster/nimbus-catalog-secrets" \
    "${CLUSTER_NAME}/rds/master-password"; do
  aws secretsmanager delete-secret --secret-id "$secret" \
    --force-delete-without-recovery --region "$REGION" 2>/dev/null \
    && echo "  Deleted: $secret" || echo "  $secret not found"
done

# ──────────────────────────────────────────────
#  Final Verification
# ──────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Running final verification scan...${NC}"
echo ""

ALL_CLEAN=true

check() {
  local label="$1" value="$2"
  if [ -n "$value" ]; then
    echo -e "  ${RED}⚠  $label: $value${NC}"
    ALL_CLEAN=false
  else
    echo -e "  ${GREEN}✅ No $label${NC}"
  fi
}

check "Running/stopped EC2 instances" "$(aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text --region "$REGION" 2>/dev/null)"
check "EKS clusters" "$(aws eks list-clusters \
  --query "clusters" --output text --region "$REGION" 2>/dev/null)"
check "Non-default VPCs" "$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=false" \
  --query "Vpcs[].VpcId" --output text --region "$REGION" 2>/dev/null)"
check "Load balancers" "$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[].LoadBalancerArn" --output text --region "$REGION" 2>/dev/null)"
check "NAT gateways" "$(aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[].NatGatewayId" --output text --region "$REGION" 2>/dev/null)"
check "Elastic IPs" "$(aws ec2 describe-addresses \
  --query "Addresses[].AllocationId" --output text --region "$REGION" 2>/dev/null)"
check "RDS instances" "$(aws rds describe-db-instances \
  --query "DBInstances[].DBInstanceIdentifier" --output text --region "$REGION" 2>/dev/null)"
check "RDS subnet groups" "$(aws rds describe-db-subnet-groups --region "$REGION" \
  --query "DBSubnetGroups[?DBSubnetGroupName!='default'].DBSubnetGroupName" \
  --output text 2>/dev/null)"
check "ElastiCache clusters" "$(aws elasticache describe-cache-clusters \
  --query "CacheClusters[].CacheClusterId" --output text --region "$REGION" 2>/dev/null)"
check "ElastiCache subnet groups" "$(aws elasticache describe-cache-subnet-groups \
  --region "$REGION" \
  --query "CacheSubnetGroups[?CacheSubnetGroupName!='default'].CacheSubnetGroupName" \
  --output text 2>/dev/null)"
check "Orphan EBS volumes" "$(aws ec2 describe-volumes \
  --filters "Name=status,Values=available" \
  --query "Volumes[].VolumeId" --output text --region "$REGION" 2>/dev/null)"
check "ECR repositories" "$(aws ecr describe-repositories \
  --query "repositories[].repositoryName" --output text --region "$REGION" 2>/dev/null)"
check "Secrets Manager (nimbus/*)" "$(aws secretsmanager list-secrets \
  --filters Key=name,Values=nimbus \
  --query "SecretList[].Name" --output text --region "$REGION" 2>/dev/null)"

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
echo -e "${YELLOW}S3 + DynamoDB preserved (near-zero cost, enables re-deployment):${NC}"
echo "  aws s3 rm s3://ibrahim-cloud-native-tf-state --recursive"
echo "  aws s3api delete-bucket --bucket ibrahim-cloud-native-tf-state"
echo "  aws dynamodb delete-table --table-name ibrahim-cloud-native-tf-lock --region $REGION"
