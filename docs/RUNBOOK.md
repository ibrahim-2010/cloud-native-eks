# NimbusRetail — Operational Runbook

**Cluster:** nimbus-cluster (us-east-1)
**Namespace:** nimbus (application), kafka, monitoring, argocd, kyverno

Before running any kubectl command, configure access:
```bash
aws eks update-kubeconfig --name nimbus-cluster --region us-east-1
```

---

## 1. Deploy a New Service Version

**Trigger:** Developer pushes to `nimbus-retail-starter` on GitHub.

**Automated path (normal):**
1. Jenkins job (`nimbus-<service>-service`) detects the push and builds automatically
2. After a successful push to ECR, Jenkins updates `helm/nimbus-service/values-<name>.yaml`
3. ArgoCD detects the Git change (within 3 minutes) and rolls out the new image

**Manual trigger:**
```bash
# In Jenkins UI: open job → Build with Parameters → run
# Or via CLI:
curl -X POST "http://admin:<password>@<jenkins-ip>:8080/job/nimbus-auth-service/build"
```

**Verify rollout:**
```bash
kubectl rollout status deploy/auth-service -n nimbus
kubectl get pods -n nimbus
```

---

## 2. Roll Back a Deployment

**Option A — ArgoCD (recommended):** revert the image tag commit in the platform repo.

```bash
cd cloud-native-eks-project
git log --oneline helm/nimbus-service/values-auth.yaml   # find the previous good commit
git revert HEAD                                          # or revert the specific commit
git push origin main
# ArgoCD auto-syncs within 3 minutes
```

**Option B — Kubernetes (faster, bypasses GitOps):**
```bash
kubectl rollout undo deploy/auth-service -n nimbus
kubectl rollout status deploy/auth-service -n nimbus
```

> **Note:** Option B creates drift between the cluster state and Git. Follow up by
> updating `values-auth.yaml` with the rolled-back image tag and pushing to Git.

---

## 3. Rotate a Secret

1. Update the value in AWS Secrets Manager:
```bash
aws secretsmanager put-secret-value \
  --secret-id nimbus-cluster/nimbus-secrets \
  --secret-string '{
    "JWT_SECRET": "<new-value>",
    "DATABASE_URL": "postgres://postgres:<pass>@<rds-endpoint>/nimbus",
    "REDIS_URL": "redis://<redis-endpoint>:6379"
  }'
```

2. Force ESO to sync immediately (normally syncs every 1 hour):
```bash
kubectl annotate externalsecret nimbus-secrets -n nimbus \
  force-sync=$(date +%s) --overwrite
```

3. Verify the Kubernetes Secret was updated:
```bash
kubectl get secret nimbus-secrets -n nimbus \
  -o jsonpath='{.data.JWT_SECRET}' | base64 -d
```

4. Restart pods to pick up the new secret value:
```bash
kubectl rollout restart deploy/auth-service deploy/cart-service deploy/order-service -n nimbus
```

---

## 4. Scale a Service

**Temporary scale (not GitOps):**
```bash
kubectl scale deploy/catalog-service --replicas=3 -n nimbus
```

**Permanent scale (GitOps):** update `replicaCount` in `values-catalog.yaml`, commit, push.

**Enable HPA on notification-service** (currently disabled — Kafka consumer):
Update `hpa.enabled: true` in `values-notification.yaml` and set appropriate metrics.
Note: CPU-based HPA is not appropriate for Kafka consumers — use KEDA with
`KafkaLag` metric instead.

---

## 5. Investigate a Pod Crash (CrashLoopBackOff)

```bash
# Step 1: identify the failing pod
kubectl get pods -n nimbus

# Step 2: view recent events
kubectl describe pod <pod-name> -n nimbus | tail -30

# Step 3: view crash logs (current instance)
kubectl logs <pod-name> -n nimbus

# Step 4: view logs from the previous (crashed) instance
kubectl logs <pod-name> -n nimbus --previous

# Step 5: check if the secret exists (common cause)
kubectl get secrets -n nimbus
kubectl get externalsecrets -n nimbus   # check ESO sync status

# Step 6: check if the image exists in ECR
aws ecr describe-images --repository-name nimbus/auth-service \
  --region us-east-1 --query "imageDetails[*].imageTags"
```

**Common causes:**

| Symptom | Likely cause | Fix |
|---|---|---|
| `secret not found` | ESO hasn't synced yet | Check ESO logs, force sync |
| `ECONNREFUSED` on port 5432 | NetworkPolicy blocking RDS egress | Check `allow-aws-egress` policy |
| `Error: JWT_SECRET is undefined` | Secret key name mismatch | Check `ExternalSecret` property mapping |
| `ImagePullBackOff` | Wrong image tag or ECR access | Check values file tag, ECR repo exists |

---

## 6. Investigate High Latency

```bash
# Step 1: check p95 latency in Prometheus
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090
# Query: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace="nimbus"}[5m])) by (job, le))

# Step 2: check error rate
# Query: sum(rate(http_requests_total{namespace="nimbus", status=~"5.."}[5m])) by (job)

# Step 3: check pod resource usage
kubectl top pods -n nimbus

# Step 4: check for OOMKilled or CPU throttling
kubectl describe pod <pod-name> -n nimbus | grep -A5 "Last State"

# Step 5: view Loki logs for error patterns
# In Grafana Explore: {namespace="nimbus", app="auth-service"} |= "error"

# Step 6: check RDS connection pool
# In Loki: {namespace="nimbus"} |= "too many connections"
```

---

## 7. Investigate Kafka Consumer Lag

```bash
# Step 1: check the NimbusKafkaConsumerLag alert in Prometheus
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090
# Query: kafka_consumergroup_lag{namespace="kafka"}

# Step 2: check notification-service is running
kubectl get pods -n nimbus -l app=notification-service
kubectl logs deploy/notification-service -n nimbus | tail -30

# Step 3: check Kafka pods are healthy
kubectl get pods -n kafka

# Step 4: if notification-service is stuck, restart it
kubectl rollout restart deploy/notification-service -n nimbus

# Step 5: check Kafka broker logs
kubectl logs -n kafka -l strimzi.io/cluster=nimbus-kafka --tail=50
```

---

## 8. Check Cluster Health (Daily/Weekly)

```bash
# Nodes
kubectl get nodes
kubectl top nodes

# All pods — anything not Running?
kubectl get pods -A | grep -v Running | grep -v Completed

# ArgoCD sync status
kubectl get applications -n argocd

# Kyverno policy violations
kubectl get policyreport -n nimbus -o jsonpath='{.results[*].message}'

# ESO sync status
kubectl get externalsecrets -n nimbus

# Prometheus targets — any DOWN?
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring 9090:9090
# Open http://localhost:9090/targets
```

---

## 9. Deploy the Stack from Scratch

```bash
# 1. Bootstrap S3 + DynamoDB (if first time)
cd cloud-native-eks-project
bash bootstrap.sh

# 2. Jenkins server
cd Jenkins-Server-TF
terraform init && terraform apply
# Wait ~5 minutes, then SSH in and run:
sudo bash /opt/setup-jcasc.sh

# 3. EKS + all infrastructure
cd ../EKS-Terraform
terraform init && terraform apply -var-file="nimbus.tfvars"

# 4. Configure kubectl
aws eks update-kubeconfig --name nimbus-cluster --region us-east-1
cp ~/.kube/config /var/lib/jenkins/.kube/config
chown -R jenkins:jenkins /var/lib/jenkins/.kube

# 5. Populate Secrets Manager
aws secretsmanager create-secret \
  --name nimbus-cluster/nimbus-secrets \
  --secret-string '{"JWT_SECRET":"...","DATABASE_URL":"...","REDIS_URL":"..."}'
aws secretsmanager create-secret \
  --name nimbus-cluster/nimbus-catalog-secrets \
  --secret-string '{"DATABASE_URL":"postgresql://...","REDIS_URL":"..."}'

# 6. Install ArgoCD
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts

# 7. Deploy app-of-apps (connects ArgoCD to the platform repo)
kubectl apply -f argocd/app-of-apps.yaml

# 8. Trigger first Jenkins builds for all 5 services
# → In Jenkins UI, run each nimbus-*-service job once to push initial images to ECR
```

---

## 10. Tear Down the Stack

```bash
cd cloud-native-eks-project
bash destroy.sh
```

The script runs in 10 phases. Full teardown takes ~15 minutes. The S3 bucket and
DynamoDB table are preserved intentionally — delete them manually only if done
with the project:

```bash
aws s3 rb s3://ibrahim-cloud-native-tf-state --force
aws dynamodb delete-table --table-name ibrahim-cloud-native-tf-lock --region us-east-1
```

---

## 11. Common Error Reference

| Error | Where seen | Fix |
|---|---|---|
| `no kind "ExternalSecret" is registered` | kubectl apply | ESO not yet deployed — run `terraform apply` first |
| `SecretSyncedError: secret does not exist` | ESO logs | Create the secret in Secrets Manager first |
| `This server does not host this topic-partition` | notification-service | Transient Kafka startup race — `restart: on-failure` handles it |
| `dependency kafka failed to start` | docker-compose | Kafka healthcheck path wrong — use `/opt/kafka/bin/kafka-topics.sh` |
| `bitnami/kafka:3.7 not found` | docker-compose pull | Image removed from Docker Hub — use `apache/kafka:3.7.2` |
| `jq: command not found` | Git Bash on Windows | Replace `jq -r .field` with `python -c "import sys,json; print(json.load(sys.stdin)['field'])"` |
| `GroupCoordinator not available` | notification-service log | Transient — KafkaJS retries automatically, not a crash |
| Jenkins Quality Gate timeout | Jenkins pipeline | Check SonarQube webhook uses private IP, not localhost |
