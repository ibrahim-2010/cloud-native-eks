# Cloud-Native DevSecOps Three-Tier Application on AWS EKS 🚀

[![LinkedIn](https://img.shields.io/badge/Connect%20with%20me%20on-LinkedIn-blue.svg)](https://www.linkedin.com/in/ibrahim)
[![GitHub](https://img.shields.io/github/stars/ibrahim-2010/cloud-native-eks.svg?style=social)](https://github.com/ibrahim-2010)
[![Live App](https://img.shields.io/badge/Live%20App-platinum--consults.com-green)](http://platinum-consults.com)

[![AWS](https://img.shields.io/badge/AWS-%F0%9F%9B%A1-orange)](https://aws.amazon.com)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-%E2%9C%A8-blue)](https://kubernetes.io)
[![Terraform](https://img.shields.io/badge/Terraform-%E2%9C%A8-lightgrey)](https://www.terraform.io)
[![Jenkins](https://img.shields.io/badge/Jenkins-CI%2FCD-red)](https://www.jenkins.io)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-orange)](https://argoproj.github.io/cd)
[![Docker](https://img.shields.io/badge/Docker-%F0%9F%90%B3-blue)](https://www.docker.com)

---

Welcome to the Cloud-Native DevSecOps Three-Tier Application Deployment project! 🚀

This repository hosts the implementation of a **Three-Tier Web App** using **ReactJS**, **Node.js**, **PostgreSQL**, and **Redis**, deployed on **AWS EKS**. The project covers a wide range of tools and practices for a robust, scalable, and secure DevOps setup.

> ⚡ **This is not a tutorial follow-along.** Every configuration, fix, and workaround in this repo comes from two real deployment cycles with real errors, real debugging, and real solutions. **13 production issues documented.**

---

## 📋 Table of Contents

- [Project Overview](#-project-overview)
- [Architecture](#-architecture)
- [Tech Stack](#-tech-stack)
- [Repository Structure](#-repository-structure)
- [Prerequisites](#-prerequisites)
- [Deployment Guide](#-deployment-guide)
- [CI/CD Pipeline Stages](#-cicd-pipeline-stages)
- [Monitoring & Alerts](#-monitoring--alerts)
- [Challenges & Solutions](#-challenges--solutions)
- [Reports](#-reports)
- [Cleanup](#-cleanup)
- [Author](#-author)

---

## 📖 Project Overview

🛠️ **Tools Explored:**

- **Terraform & AWS CLI** for AWS infrastructure provisioning
- **Jenkins, SonarQube, Trivy** for DevSecOps CI/CD pipeline
- **Docker & ECR** for containerization and private registry
- **EKS & kubectl** for Kubernetes orchestration
- **Helm, Prometheus, and Grafana** for monitoring & alerting
- **ArgoCD** for GitOps practices
- **Route 53 & ALB** for DNS and load balancing

🚢 **High-Level Overview:**

- IAM User setup & Terraform magic on AWS
- Jenkins deployment with SonarQube and Trivy integration
- EKS Cluster creation & ALB Ingress Controller configuration
- Private ECR repositories for secure image management
- 9-stage DevSecOps pipeline with security scanning at every layer
- GitOps with ArgoCD — Git as the single source of truth
- Custom Prometheus alerting rules for production readiness
- DNS configuration with Route 53 for custom domain access

📈 **The journey covered everything from setting up tools to deploying a Three-Tier app, implementing security scanning, ensuring data persistence, setting up monitoring, and debugging 13 real production issues across two full deployment cycles.**

---

## 🏗️ Architecture

![Architecture Diagram](assets/architecture.png)

**CI/CD Flow:**
```
Code Push → Jenkins → SonarQube Analysis → Quality Gate → Trivy FS Scan
    → Docker Build → Trivy Image Scan → Push to ECR
    → Update K8s Manifest in Git → ArgoCD Auto-Deploy → EKS
```

---

## 🧰 Tech Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| ☁️ **Cloud** | AWS (us-east-1) | EKS, ECR, ALB, Route 53, IAM, EBS, S3 |
| ⎈ **Orchestration** | Kubernetes (EKS) | Container orchestration, service discovery |
| ⚛️ **Frontend** | React + Nginx | SPA served via multi-stage Docker build (~25MB) |
| 🟢 **Backend** | Node.js + Express | REST API with health checks, CRUD operations |
| 🐘 **Database** | PostgreSQL 15 | Persistent storage with PVC on EBS |
| 🔴 **Cache** | Redis 7 Alpine | In-memory caching with TTL, LRU eviction |
| 🔧 **CI/CD** | Jenkins | 9-stage automated DevSecOps pipeline |
| 🔍 **Code Quality** | SonarQube | Static analysis, quality gates |
| 🛡️ **Security** | Trivy | Filesystem + image vulnerability scanning |
| 🔄 **GitOps** | ArgoCD | Automatic deployment from Git state |
| 📝 **IaC** | Terraform | Jenkins server with S3 remote state |
| 📊 **Monitoring** | Prometheus + Grafana | Metrics, dashboards, custom alerts |
| 🌐 **DNS** | Route 53 | Domain management, ALB alias records |
| 📦 **Registry** | Amazon ECR | Private Docker image storage |
| 🚪 **Ingress** | AWS LB Controller | L7 load balancing, path-based routing |

---

## 📁 Repository Structure

```
cloud-native-eks/
├── 📂 Application-Code/
│   ├── 📂 backend/                    # Node.js Express API
│   │   ├── server.js                   # CRUD API + health checks + Redis caching
│   │   ├── Dockerfile                  # Alpine-based, non-root user, healthcheck
│   │   └── package.json
│   └── 📂 frontend/                   # React Single Page Application
│       ├── src/App.js                  # Task manager with live health indicators
│       ├── Dockerfile                  # Multi-stage build (Node → Nginx, ~25MB)
│       └── nginx.conf                  # SPA routing, security headers
├── 📂 Jenkins-Pipeline-Code/
│   ├── Jenkinsfile-Backend             # 9-stage DevSecOps pipeline
│   └── Jenkinsfile-Frontend            # 9-stage DevSecOps pipeline
├── 📂 Jenkins-Server-TF/
│   ├── main.tf                         # EC2, SG, IAM role + instance profile
│   ├── backend.tf                      # S3 + DynamoDB remote state
│   ├── variables.tf                    # Region, instance type, key name
│   ├── outputs.tf                      # Jenkins URL, SonarQube URL, SSH command
│   └── tools-install.sh                # Bootstrap script (13 tools)
├── 📂 Kubernetes-Manifests-file/
│   ├── 📂 Database/
│   │   ├── postgres.yaml               # Secret + PVC + Deployment + Service
│   │   └── redis.yaml                  # Deployment + Service
│   ├── 📂 Backend/
│   │   └── deployment.yaml             # Deployment + Service
│   ├── 📂 Frontend/
│   │   └── deployment.yaml             # Deployment + Service
│   ├── ingress.yaml                    # ALB with path-based routing
│   └── monitoring-alerts.yaml          # Custom PrometheusRule (5 alerts)
├── 📂 docs/
│   └── ISSUES-REPORT.md                # Detailed report on all 13 issues
├── 📂 .github/workflows/
│   └── ci.yml                          # YAML + Terraform validation
├── .gitignore
├── LICENSE
└── README.md
```

---

## ✅ Prerequisites

- AWS Account with IAM user (EC2, EKS, ECR, S3, Route 53, IAM, VPC, CloudFormation)
- AWS CLI v2 configured locally
- Terraform >= 1.9.0
- **vCPU quota ≥ 16** (request at: EC2 → Limits → Running On-Demand Standard instances)
- Git & GitHub account with PAT
- Domain name with ability to change nameservers
- SSH key pair in us-east-1

---

## 🚀 Deployment Guide

### Phase 1: AWS Foundation
Create S3 bucket + DynamoDB for Terraform state, EC2 key pair, and ECR repositories.

### Phase 2: Provision Jenkins Server
Terraform provisions an m7i-flex.large EC2 with Jenkins, Docker, SonarQube, Terraform, AWS CLI, kubectl, eksctl, Helm, Trivy, and sonar-scanner.

### Phase 3: Configure Jenkins & SonarQube
Unlock Jenkins, install plugins, create credentials (github-creds + github-token), configure SonarQube server and webhook.

### Phase 4: Create EKS Cluster
```bash
eksctl create cluster --name cloud-native-cluster --region us-east-1 \
  --zones us-east-1a,us-east-1b --nodegroup-name worker-nodes \
  --node-type t3.xlarge --nodes 2 --nodes-min 2 --nodes-max 3 --managed
```
Create namespaces, install EBS CSI driver, copy kubeconfig to Jenkins user.

### Phase 5: Deploy Database Layer
```bash
kubectl apply -f Kubernetes-Manifests-file/Database/
```

### Phase 6: Build & Deploy Application
Bootstrap: Build Docker images → Push to ECR → Update manifests → Deploy → **Push to Git before ArgoCD**.

### Phase 7: ALB Ingress Controller
Install AWS Load Balancer Controller via Helm. **Update IAM policy with broader permissions** immediately after creation.

### Phase 8: ArgoCD GitOps
```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts
```
Create 3 applications with automatic sync + prune + self-heal.

### Phase 9: Jenkins CI/CD Pipelines
Create backend and frontend pipeline jobs. Run Build Now to verify full DevSecOps pipeline.

### Phase 10: Monitoring Stack
```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --timeout 10m
```
Apply custom PrometheusRule alerts. Access Grafana via LoadBalancer.

### Phase 11: Domain & DNS
Create Route 53 hosted zone, update nameservers at registrar, create A record alias to ALB.

> 📖 **For the complete step-by-step guide with every command, see the [Full Deployment Guide](docs/DEPLOYMENT-GUIDE.md)**

---

## 🔄 CI/CD Pipeline Stages

Both backend and frontend pipelines execute these **9 stages**:

| # | Stage | Tool | Purpose |
|---|-------|------|---------|
| 1 | 🧹 Cleanup Workspace | Jenkins | Wipe workspace for fresh build |
| 2 | 📥 Checkout Code | Git | Clone repo from GitHub |
| 3 | 🔍 SonarQube Analysis | sonar-scanner | Static code analysis |
| 4 | ✅ Quality Gate | SonarQube | Pass/fail gate on code quality |
| 5 | 🛡️ Trivy FS Scan | Trivy | Scan source for vulnerabilities |
| 6 | 🐳 Docker Build & Tag | Docker | Build container image |
| 7 | 🛡️ Trivy Image Scan | Trivy | Scan image for CVEs |
| 8 | 📤 Push to ECR | AWS ECR | Push to private registry |
| 9 | 📝 Update Manifest | sed + git | Update YAML, trigger ArgoCD |

> After Stage 9, **ArgoCD** detects the Git change within 3 minutes and automatically deploys the new version. Zero manual intervention.

---

## 📊 Monitoring & Alerts

### Custom PrometheusRule Alerts

| Alert | Condition | Severity |
|-------|-----------|----------|
| 🔴 PodDown | Available replicas < desired | Critical |
| 🟡 HighCPUUsage | CPU > 80% for 2 minutes | Warning |
| 🔴 PodCrashLooping | Repeated restarts over 15 min | Critical |
| 🔴 PostgreSQLDown | Zero PostgreSQL pods | Critical |
| 🔴 RedisDown | Zero Redis pods | Critical |

---

## ⚠️ Challenges & Solutions

**13 real issues** encountered across two full deployment cycles. Not hypothetical — all documented from actual debugging sessions.

| # | Challenge | Root Cause | Solution |
|---|-----------|-----------|----------|
| 1 | `eks:DescribeClusterVersions` denied | Managed policies miss newer EKS APIs | Inline policy with `eks:*` |
| 2 | Instance profile creds cached | IMDS caches IAM credentials | Export credentials directly |
| 3 | `npm ci` build failure | No `package-lock.json` | Use `npm install --omit=dev` |
| 4 | ArgoCD CRD too large | Annotations > 262144 bytes | `--server-side --force-conflicts` |
| 5 | ArgoCD overwrote working pods | Git had placeholder values | Push to Git BEFORE ArgoCD |
| 6 | Pods Pending (pod limit) | t3.small ENI: 11 pods/node | Upgrade to t3.xlarge |
| 7 | Can't add 4th node | vCPU quota limit of 8 | Request increase to 20 |
| 8 | Quality Gate timeout | No SonarQube webhook | Add webhook to Jenkins |
| 9 | SCM credential empty | Wrong credential type | Username with password type |
| 10 | `sonar-scanner` not found | User-data failed silently | Manual install |
| 11 | ALB not provisioning | IAM policy missing new actions | Broader ELB + EC2 permissions |
| 12 | `ImagePullBackOff` | Stale image tags from old builds | sed to correct tags |
| 13 | Ingress ADDRESS empty | Ingress before controller | Delete and reapply |

> 📖 **For detailed root cause analysis, investigation steps, and prevention strategies, see the [Full Issues Report](docs/ISSUES-REPORT.md)**

---

## 📈 Reports

### Infrastructure Summary

| Resource | Specification | Count |
|----------|--------------|-------|
| EKS Cluster | Kubernetes v1.34, us-east-1 | 1 |
| Worker Nodes | t3.xlarge (4 vCPU, 16GB RAM) | 2 |
| Jenkins Server | m7i-flex.large (EC2) | 1 |
| Application Load Balancer | Internet-facing, path-based routing | 1 |
| ECR Repositories | frontend, backend | 2 |
| EBS Volumes | gp2, 5Gi (PostgreSQL PVC) | 1 |
| Route 53 Hosted Zone | platinum-consults.com | 1 |

### Application Stack

| Component | Image | Port | Health Check |
|-----------|-------|------|-------------|
| Frontend | React + Nginx (~25MB) | 80 | /nginx-health |
| Backend API | Node.js 18 Alpine | 3001 | /api/health |
| PostgreSQL | postgres:15-alpine | 5432 | pg_isready |
| Redis | redis:7-alpine | 6379 | redis-cli ping |

### Security Report

| Check | Tool | Result |
|-------|------|--------|
| Code Quality | SonarQube | ✅ Quality Gate Passed |
| Source Vulnerabilities | Trivy FS | ✅ No Critical blocking |
| Image CVEs | Trivy Image | ✅ Scanned |
| Secrets Management | K8s Secrets + Jenkins | ✅ No hardcoded secrets |
| Container Runtime | Non-root user | ✅ Security best practice |
| Database Access | ClusterIP | ✅ Not exposed to internet |

---

## 🧹 Cleanup

```bash
# 1. ArgoCD apps
kubectl delete applications --all -n argocd

# 2. Monitoring
helm uninstall monitoring -n monitoring

# 3. ArgoCD
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 4. EKS cluster (10-15 min)
eksctl delete cluster --name cloud-native-cluster --region us-east-1

# 5. ECR repos
aws ecr delete-repository --repository-name frontend --region us-east-1 --force
aws ecr delete-repository --repository-name backend --region us-east-1 --force

# 6. Jenkins server
cd Jenkins-Server-TF/ && terraform destroy -auto-approve

# 7. Manual check: EC2, EBS, ELBs, CloudFormation, Elastic IPs
```

---

## 👤 Author

**Ibrahim** — DevOps Engineer

[![GitHub](https://img.shields.io/badge/GitHub-ibrahim--2010-black?style=for-the-badge&logo=github)](https://github.com/ibrahim-2010)
[![Live App](https://img.shields.io/badge/Live_App-platinum--consults.com-green?style=for-the-badge)](http://platinum-consults.com)

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).

Happy Deploying! 🚀