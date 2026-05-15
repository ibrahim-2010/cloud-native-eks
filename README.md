# NimbusRetail — Cloud-Native Microservices Platform on AWS EKS

[![LinkedIn](https://img.shields.io/badge/Connect-LinkedIn-blue.svg)](https://www.linkedin.com/in/ibrahim-jinadu-2388b73b8/)
[![GitHub](https://img.shields.io/github/stars/ibrahim-2010/cloud-native-eks.svg?style=social)](https://github.com/ibrahim-2010/cloud-native-eks)
[![Live App](https://img.shields.io/badge/Live-platinum--consults.com-brightgreen)](http://platinum-consults.com)
[![Grafana](https://img.shields.io/badge/Grafana-grafana.platinum--consults.com-orange)](http://grafana.platinum-consults.com)
[![Prometheus](https://img.shields.io/badge/Prometheus-prometheus.platinum--consults.com-red)](http://prometheus.platinum-consults.com)

[![AWS EKS](https://img.shields.io/badge/AWS%20EKS-1.31-orange)](https://aws.amazon.com/eks/)
[![Terraform](https://img.shields.io/badge/Terraform-IaC-7B42BC)](https://www.terraform.io)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-EF7B4D)](https://argoproj.github.io/cd)
[![Jenkins](https://img.shields.io/badge/Jenkins-CI%2FCD-D24939)](https://www.jenkins.io)
[![Kafka](https://img.shields.io/badge/Strimzi-Kafka-231F20)](https://strimzi.io)
[![Kyverno](https://img.shields.io/badge/Kyverno-Policy-blue)](https://kyverno.io)

---

## Overview

NimbusRetail is a **production-grade cloud-native e-commerce platform** built on AWS EKS with a microservices architecture. Five independent services communicate synchronously via HTTP and asynchronously via Apache Kafka, backed by managed AWS RDS and ElastiCache.

The entire platform — from VPC to running pods — is deployed through a single Jenkins pipeline with zero manual steps. GitOps via ArgoCD keeps the cluster in sync with Git on every commit.

> Built across multiple deployment cycles. **14 production issues encountered and resolved.** Every fix is documented in [`docs/ISSUES-REPORT.md`](docs/ISSUES-REPORT.md).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Internet                                                               │
│     │                                                                   │
│     ▼                                                                   │
│  Route 53 (platinum-consults.com)  ←─── ExternalDNS (auto-managed)     │
│     │                                                                   │
│     ▼                                                                   │
│  AWS ALB (internet-facing)  ←─── AWS Load Balancer Controller           │
│     │                                                                   │
│     ├──/auth/*──────► auth-service       (Node.js / Express)  :3001    │
│     ├──/products*───► catalog-service    (Python / FastAPI)   :3002    │
│     ├──/cart/*──────► cart-service       (Node.js / Express)  :3003    │
│     ├──/orders*─────► order-service      (Node.js / Express)  :3004    │
│     └──/──────────── frontend            (nginx static)       :80      │
│                                                                         │
│  ┌─────── nimbus namespace ─────────────────────────────────────────┐  │
│  │                                                                   │  │
│  │  auth ──Kafka──► notification-service  (Node.js Kafka consumer)  │  │
│  │  order─────────►                                                  │  │
│  │                                                                   │  │
│  │  All services ──► RDS PostgreSQL 16   (AWS managed, private)     │  │
│  │  cart/catalog  ──► ElastiCache Redis  (AWS managed, private)     │  │
│  │  auth/order    ──► Strimzi Kafka      (KRaft, 3 brokers, gp3)   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌─────── platform ──────────────────────────────────────────────────┐  │
│  │  ArgoCD         GitOps controller — watches GitHub/main           │  │
│  │  ESO            Syncs secrets from AWS Secrets Manager → K8s      │  │
│  │  Kyverno        Admission control — resource limits, policies      │  │
│  │  Prometheus     Metrics scraping across all namespaces             │  │
│  │  Grafana        Dashboards at grafana.platinum-consults.com        │  │
│  │  Loki           Log aggregation                                    │  │
│  │  Tempo          Distributed tracing                                │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  Jenkins EC2 ──► runs Terraform ──► EKS + RDS + Redis + ECR            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Technology | Detail |
|---|---|---|
| **Cloud** | AWS us-east-1 | EKS 1.31, RDS PostgreSQL 16, ElastiCache Redis 7, ECR, ALB, Route 53, Secrets Manager |
| **Orchestration** | Kubernetes (EKS) | 2 × t3.xlarge nodes, OIDC provider, IRSA per service |
| **IaC** | Terraform | 40+ resources — VPC, EKS, RDS, Redis, Helm releases, IAM, namespaces |
| **GitOps** | ArgoCD | App-of-Apps pattern — one `kubectl apply` bootstraps everything |
| **CI/CD** | Jenkins + JCasC | 6 pipelines, 102 plugins, zero-click setup via JCasC |
| **Messaging** | Strimzi Kafka | KRaft mode, 3 brokers, gp3 EBS PVCs, in-cluster |
| **Services** | Node.js + Python | auth/cart/order/notification (Express), catalog (FastAPI) |
| **Frontend** | nginx | Static HTML/JS served from ConfigMap, ALB Ingress |
| **Secrets** | External Secrets Operator | Pulls from AWS Secrets Manager, zero plaintext in Git |
| **Policy** | Kyverno | Resource limits enforcement, security policies |
| **Observability** | Prometheus + Grafana | Metrics + dashboards at `grafana.platinum-consults.com` |
| **Logs** | Loki | Log aggregation, Grafana datasource |
| **Tracing** | Tempo | Distributed tracing, Grafana datasource |
| **DNS** | ExternalDNS + Route 53 | Auto-creates A records from Ingress annotations |
| **Ingress** | AWS Load Balancer Controller | ALB with path-based routing, IP target mode |
| **Security** | Trivy + SonarQube | Image CVE scanning + code quality gates in every build |
| **Storage** | gp3 StorageClass (EBS CSI) | Default cluster StorageClass, encrypted |

---

## Services

| Service | Language | Port | Responsibilities |
|---|---|---|---|
| **auth-service** | Node.js / Express | 3001 | User registration, login, JWT issuance, Kafka producer |
| **catalog-service** | Python / FastAPI | 3002 | Product listing, inventory, Redis caching |
| **cart-service** | Node.js / Express | 3003 | Shopping cart (JSONB in PostgreSQL), Redis caching |
| **order-service** | Node.js / Express | 3004 | Order creation, Kafka producer → notification |
| **notification-service** | Node.js | 3005 | Kafka consumer — dispatches confirmation emails |
| **frontend** | nginx | 80 | Static UI — register, browse, add to cart, place order |

All services expose `/healthz`, `/readyz`, and `/metrics` (Prometheus format).

---

## Repository Structure

```
cloud-native-eks/
│
├── EKS-Terraform/                  # Full EKS platform — IaC
│   ├── main.tf                     # VPC, EKS cluster, node groups, OIDC
│   ├── rds.tf                      # RDS PostgreSQL 16, private subnets
│   ├── elasticache.tf              # ElastiCache Redis 7
│   ├── ebs-csi.tf                  # EBS CSI driver + gp3 StorageClass
│   ├── alb-controller.tf           # ALB controller IRSA
│   ├── helm-alb.tf                 # ALB controller Helm release
│   ├── helm-strimzi.tf             # Strimzi Kafka operator
│   ├── helm-eso.tf                 # External Secrets Operator
│   ├── helm-kyverno.tf             # Kyverno admission controller
│   ├── helm-monitoring.tf          # Prometheus + Grafana (kube-prometheus-stack)
│   ├── helm-loki.tf                # Loki log aggregation
│   ├── helm-tempo.tf               # Tempo distributed tracing
│   ├── helm-external-dns.tf        # ExternalDNS + Route 53
│   ├── irsa-nimbus.tf              # IRSA roles for ESO + service accounts
│   ├── ecr.tf                      # 5 ECR repos (nimbus/*)
│   ├── namespaces.tf               # Kubernetes provider + namespaces
│   └── nimbus.tfvars               # Cluster config (committed — gitignore exception)
│
├── Jenkins-Server-TF/              # Jenkins EC2 server — IaC
│   ├── main.tf                     # EC2, IAM role with inline policies, SG
│   ├── tools-install.sh            # Installs Jenkins, Docker, Terraform, kubectl, Trivy, SonarQube
│   └── jcasc/
│       ├── jenkins.yaml            # JCasC — credentials, SonarQube, 6 pipeline jobs
│       └── setup-jcasc.sh         # One-command: inject secrets, enable SSH as jenkins user
│
├── Jenkins-Pipeline-Code/
│   ├── Jenkinsfile-Infrastructure  # 9-stage pipeline: EKS + full platform deploy
│   └── Jenkinsfile-Nimbus          # 9-stage DevSecOps: SonarQube → Trivy → ECR → ArgoCD
│
├── helm/nimbus-service/            # Shared Helm chart for all 5 services
│   ├── Chart.yaml
│   ├── templates/                  # Deployment, Service, HPA
│   ├── values.yaml                 # Base defaults
│   ├── values-auth.yaml            # auth-service overrides
│   ├── values-catalog.yaml         # catalog-service overrides
│   ├── values-cart.yaml            # cart-service overrides
│   ├── values-order.yaml           # order-service overrides
│   └── values-notification.yaml    # notification-service overrides
│
├── Kubernetes-Manifests-file/
│   ├── Kafka/kafka-cluster.yaml    # Strimzi KafkaCluster CR (KRaft, 3 brokers, gp3)
│   ├── Nimbus-Frontend/            # nginx Deployment + ConfigMap + ALB Ingress
│   ├── Monitoring/                 # Prometheus ServiceMonitors + alert rules
│   ├── Security/                   # ExternalSecret, SecretStore, Kyverno policies, NetworkPolicies
│   ├── grafana-ingress.yaml        # ALB Ingress for Grafana + Prometheus (shared ALB group)
│   └── monitoring-alerts.yaml      # PrometheusRule — nimbus namespace alerts
│
├── argocd/
│   ├── app-of-apps.yaml            # Root app — watches argocd/apps/
│   └── apps/                       # One YAML per child app (auto-discovered)
│       ├── nimbus-auth.yaml
│       ├── nimbus-catalog.yaml
│       ├── nimbus-cart.yaml
│       ├── nimbus-order.yaml
│       ├── nimbus-notification.yaml
│       ├── nimbus-frontend.yaml
│       ├── nimbus-kafka.yaml
│       ├── nimbus-security.yaml
│       ├── nimbus-monitoring.yaml
│       ├── nimbus-namespace.yaml
│       └── monitoring-ingress.yaml
│
├── docs/
│   ├── SDD.md                      # System Design Document
│   ├── DEPLOYMENT-GUIDE.md         # Step-by-step with all error fixes documented
│   ├── ISSUES-REPORT.md            # 14 production issues + root causes + fixes
│   ├── RUNBOOK.md                  # Ops runbook for day-2 operations
│   └── ADRs/                       # Architecture Decision Records
│       ├── ADR-001-strimzi-over-msk.md
│       ├── ADR-002-shared-helm-chart.md
│       ├── ADR-003-external-secrets-operator.md
│       ├── ADR-004-kyverno-admission-control.md
│       └── ADR-005-loki-over-cloudwatch.md
│
├── bootstrap.sh                    # One-command: S3, DynamoDB, key pair
├── destroy.sh                      # Ordered teardown — 11 phases, zero orphans
└── README.md
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS Account | IAM user with programmatic access |
| EC2 vCPU quota | ≥ 20 in us-east-1 (2 × t3.xlarge = 16 vCPUs) |
| AWS CLI v2 | Configured with `aws configure` |
| Terraform ≥ 1.9 | Local install |
| Git + GitHub PAT | `repo` scope (read + write) |
| Domain name | With ability to update nameservers to Route 53 |

---

## Deployment (5 Steps, ~45 min)

Everything after Step 3 runs entirely from the Jenkins server. No local Terraform apply for EKS.

### Step 1 — Push to GitHub
```bash
cd cloud-native-eks-project
git add . && git commit -m "deploy" && git push origin main
```
> ArgoCD and `setup-jcasc.sh` pull from GitHub. Code must be on GitHub before deploying.

### Step 2 — Bootstrap (~3 min)
```bash
bash bootstrap.sh
```
Creates: S3 state bucket, DynamoDB lock table, EC2 key pair. Idempotent — safe to re-run.

### Step 3 — Deploy Jenkins Server (~5 min)
```bash
cd Jenkins-Server-TF
terraform init && terraform apply -auto-approve
terraform output jenkins_public_ip   # note the IP
```

SSH in and wait for tools to install (~5 min):
```bash
ssh -i ../test.pem ubuntu@<JENKINS_IP>
sudo tail -f /var/log/tools-install.log   # wait for: Installation Complete
sudo bash /opt/setup-jcasc.sh             # interactive: injects secrets, creates 6 jobs
```

After the script completes — **all future SSH sessions use jenkins user directly**:
```bash
ssh -i ../test.pem jenkins@<JENKINS_IP>
```

### Step 4 — Run Infrastructure Pipeline (~30 min)

Open Jenkins at `http://<JENKINS_IP>:8080` → **`nimbus-infrastructure`** → **Build Now**

| Stage | What it does |
|---|---|
| Checkout | Clones platform repo from GitHub |
| Terraform Init | Downloads providers (~500 MB on first run) |
| Terraform Apply — EKS Cluster | Creates EKS + node group (provider needs endpoint before K8s resources) |
| Terraform Apply — Full Stack | RDS, Redis, Strimzi, ESO, Kyverno, Loki, Tempo, Prometheus/Grafana, ALB, ExternalDNS, ECR, IRSA |
| Configure kubectl | Updates `/var/lib/jenkins/.kube/config` |
| Populate Secrets Manager | Creates `nimbus-cluster/nimbus-secrets` + `nimbus-catalog-secrets` with RDS/Redis values |
| Install ArgoCD | Installs ArgoCD, exposes via LoadBalancer, prints admin password |
| Deploy App-of-Apps | `kubectl apply -f argocd/app-of-apps.yaml` — ArgoCD takes over |
| Initialize Database | Waits for ESO to sync secrets, then runs psql Job to create all schemas + seed catalog |

Pipeline prints all access URLs on completion.

### Step 5 — Trigger Service Builds

Run each job once in Jenkins (can run all 5 in parallel):

| Job | Builds |
|---|---|
| `nimbus-auth-service` | auth-service |
| `nimbus-catalog-service` | catalog-service |
| `nimbus-cart-service` | cart-service |
| `nimbus-order-service` | order-service |
| `nimbus-notification-service` | notification-service |

Each build runs 9 stages: Cleanup → Checkout → SonarQube → Quality Gate → Trivy FS → Docker Build → Trivy Image → ECR Push → Update Helm values → ArgoCD rollout.

---

## CI/CD Pipeline

```
Code Push (nimbus-retail-starter)
    │
    ▼
Jenkins (nimbus-*-service job)
    │
    ├─ 1. Cleanup workspace
    ├─ 2. Git checkout
    ├─ 3. SonarQube analysis
    ├─ 4. Quality Gate (blocks on failure)
    ├─ 5. Trivy filesystem scan
    ├─ 6. Docker build
    ├─ 7. Trivy image scan
    ├─ 8. Push to ECR (022374769206.dkr.ecr.us-east-1.amazonaws.com/nimbus/<service>)
    └─ 9. Update image tag in helm/nimbus-service/values-<service>.yaml → git push
              │
              ▼
         ArgoCD detects Git change → rolling update on EKS
```

---

## Platform Access

| Service | URL | Credentials |
|---|---|---|
| **NimbusRetail** | `http://platinum-consults.com` | — |
| **Grafana** | `http://grafana.platinum-consults.com` | admin / CloudNative2026! |
| **Prometheus** | `http://prometheus.platinum-consults.com` | — |
| **ArgoCD** | `https://<argocd-lb>` (printed by pipeline) | admin / (printed by pipeline) |
| **Jenkins** | `http://<JENKINS_IP>:8080` | admin / your chosen password |
| **SonarQube** | `http://<JENKINS_IP>:9000` | admin / SonarAdmin2026! |

Get ArgoCD URL any time:
```bash
kubectl get svc argocd-server -n argocd
# → EXTERNAL-IP column → https://<that-value>
```

---

## Security

| Control | Implementation |
|---|---|
| **Secrets** | Zero plaintext in Git — AWS Secrets Manager → ESO → K8s Secret |
| **IRSA** | Pod-level AWS permissions via OIDC — no node-level credentials |
| **Admission Control** | Kyverno enforces CPU/memory limits on every pod in `nimbus` namespace |
| **Network Policies** | Kubernetes NetworkPolicies restrict east-west traffic per service |
| **RDS SSL** | All DB connections use `sslmode=require` |
| **Image Scanning** | Trivy scans filesystem + Docker image in every CI build |
| **Code Quality** | SonarQube quality gate blocks deployment on failure |
| **Least Privilege** | Jenkins IAM role scoped to required services only |
| **Private Subnets** | RDS and ElastiCache in private subnets — not reachable from internet |

---

## Observability

| Signal | Tool | Access |
|---|---|---|
| **Metrics** | Prometheus + kube-prometheus-stack | `prometheus.platinum-consults.com` |
| **Dashboards** | Grafana | `grafana.platinum-consults.com` |
| **Logs** | Loki | Grafana datasource |
| **Traces** | Tempo | Grafana datasource |
| **Alerts** | PrometheusRule | PodDown, HighCPUUsage, PodCrashLooping, HighErrorRate, KafkaConsumerLag |
| **Service Monitors** | ServiceMonitor CRs | Scrapes `/metrics` from all 5 nimbus services |

---

## Architecture Decision Records

| ADR | Decision | Why |
|---|---|---|
| [ADR-001](docs/ADRs/ADR-001-strimzi-over-msk.md) | Strimzi over AWS MSK | Cost — MSK is ~$0.21/hr vs Strimzi in-cluster at $0; CNCF approved |
| [ADR-002](docs/ADRs/ADR-002-shared-helm-chart.md) | Single shared Helm chart | All 5 services share one chart, differentiated by values files — no duplication |
| [ADR-003](docs/ADRs/ADR-003-external-secrets-operator.md) | ESO over K8s Secrets in Git | Zero secrets in version control; AWS Secrets Manager as single source of truth |
| [ADR-004](docs/ADRs/ADR-004-kyverno-admission-control.md) | Kyverno over OPA | Native Kubernetes policy language; simpler than Rego |
| [ADR-005](docs/ADRs/ADR-005-loki-over-cloudwatch.md) | Loki over CloudWatch | Cost — CloudWatch ingestion is expensive; Loki integrates natively with Grafana |

---

## Key Engineering Challenges

14 issues resolved across deployment cycles — [full report](docs/ISSUES-REPORT.md).

| # | Issue | Root Cause | Fix |
|---|---|---|---|
| 1 | Kubernetes provider → localhost:80 | EKS endpoint empty at Terraform plan time | Two-stage Terraform apply |
| 2 | Wrong cluster name in AWS | `*.tfvars` gitignored | Added `!EKS-Terraform/nimbus.tfvars` exception |
| 3 | ESO namespace not found | `nimbus` NS created by ArgoCD (too late) | Added `kubernetes_namespace.nimbus` to Terraform |
| 4 | Kafka PVCs unbound | No StorageClass in cluster | Added gp3 StorageClass via EBS CSI Terraform |
| 5 | Services failing — no SSL | RDS requires SSL, pg defaults to plaintext | `?sslmode=require` + `NODE_TLS_REJECT_UNAUTHORIZED=0` |
| 6 | Grafana CrashLoopBackOff | Multiple default datasources | `sidecar.datasources.isDefaultDatasource = false` |
| 7 | ExternalDNS conflict | Two ingresses claiming same hostname | Removed host from legacy ingress spec |
| 8 | ALB 503 on all API calls | Health check path `/` not exposed by services | Changed to `/healthz` + nginx config |
| 9 | Database schemas missing | init-db.sql only runs in docker-compose | Added psql Kubernetes Job to Jenkins pipeline |
| 10 | Kyverno ALB webhook errors | ALB controller not ready when Kyverno installed | `depends_on = [helm_release.alb_controller]` |

---

## Verification

```bash
aws eks update-kubeconfig --name nimbus-cluster --region us-east-1

kubectl get nodes                          # 2 nodes Ready
kubectl get pods -n nimbus                 # 6 pods Running (5 services + frontend)
kubectl get pods -n kafka                  # 3 nimbus-kafka-dual-role-* Running
kubectl get pods -n monitoring             # prometheus, grafana, loki, tempo Running
kubectl get applications -n argocd         # all Synced + Healthy
kubectl get externalsecrets -n nimbus      # READY=True, STATUS=SecretSynced
kubectl get ingress nimbus-ingress -n nimbus  # ADDRESS = ALB DNS name
```

End-to-end smoke test:
1. Open `http://platinum-consults.com`
2. Register → Login → Load products → Add to cart → Place order
3. Check notification-service logs — Kafka delivers order confirmation event

---

## Cost (~$0.51/hr while running)

| Resource | Type | $/hr |
|---|---|---|
| EKS control plane | — | $0.10 |
| Worker nodes × 2 | t3.xlarge | $0.33 |
| RDS PostgreSQL | db.t3.micro | $0.017 |
| ElastiCache Redis | cache.t3.micro | $0.017 |
| Jenkins EC2 | t3.medium | $0.042 |
| **Total** | | **~$0.51/hr** |

> S3 + DynamoDB (Terraform state) cost < $0.01/month and are preserved across deployments.

---

## Teardown

```bash
bash destroy.sh
```

11 ordered phases: ArgoCD apps → observability stack → security stack → ArgoCD → Kafka → application namespaces → Route 53 → VPC dependencies (ALBs, target groups, ENIs) → EKS (Terraform) → ECR → Jenkins.

Final verification scan checks all billable resource types and reports anything remaining.

---

## Documentation

| Document | Content |
|---|---|
| [`docs/SDD.md`](docs/SDD.md) | System Design Document — full architecture with Mermaid diagram |
| [`docs/DEPLOYMENT-GUIDE.md`](docs/DEPLOYMENT-GUIDE.md) | Step-by-step deployment with every error and fix |
| [`docs/ISSUES-REPORT.md`](docs/ISSUES-REPORT.md) | 14 production issues — root cause + fix for each |
| [`docs/RUNBOOK.md`](docs/RUNBOOK.md) | Day-2 operations — scaling, rollback, secret rotation |
| [`docs/ADRs/`](docs/ADRs/) | 5 Architecture Decision Records |

---

## Author

**Ibrahim Jinadu** — Platform / DevOps Engineer

[![LinkedIn](https://img.shields.io/badge/LinkedIn-ibrahim--jinadu-blue?style=for-the-badge&logo=linkedin)](https://www.linkedin.com/in/ibrahim-jinadu-2388b73b8/)
[![GitHub](https://img.shields.io/badge/GitHub-ibrahim--2010-black?style=for-the-badge&logo=github)](https://github.com/ibrahim-2010)
[![Live App](https://img.shields.io/badge/Live_App-platinum--consults.com-brightgreen?style=for-the-badge)](http://platinum-consults.com)

---

## License

MIT License — see [LICENSE](LICENSE) for details.
