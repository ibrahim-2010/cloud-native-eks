# Cloud-Native EKS Project — Complete Deployment Guide

> Tested and verified across two full deployment cycles. Every command in this guide is the one that actually worked — not the one that was supposed to work.

---

## Table of Contents

- [Phase 1: AWS Foundation](#phase-1-aws-foundation)
- [Phase 2: Provision Jenkins Server](#phase-2-provision-jenkins-server)
- [Phase 3: Configure Jenkins, SonarQube & Credentials](#phase-3-configure-jenkins-sonarqube--credentials)
- [Phase 4: Create EKS Cluster](#phase-4-create-eks-cluster)
- [Phase 5: Deploy Database Layer](#phase-5-deploy-database-layer)
- [Phase 6: Build & Deploy Application](#phase-6-build--deploy-application)
- [Phase 7: ALB Ingress Controller](#phase-7-alb-ingress-controller)
- [Phase 8: ArgoCD GitOps](#phase-8-argocd-gitops)
- [Phase 9: Jenkins CI/CD Pipelines](#phase-9-jenkins-cicd-pipelines)
- [Phase 10: Monitoring Stack](#phase-10-monitoring-stack)
- [Phase 11: Route 53 & Domain](#phase-11-route-53--domain)
- [Cleanup](#cleanup)

---

## Prerequisites

Before starting, ensure you have:

- AWS account with IAM user credentials (Access Key + Secret Key)
- IAM user policies: EC2, EKS, ECR, S3, Route 53, IAM, VPC, CloudFormation full access
- **vCPU quota of at least 16** — request increase before starting:
  - AWS Console → EC2 → Limits → Search "Running On-Demand Standard instances" → Request increase to 20
  - Or via CLI:
    ```bash
    aws service-quotas request-service-quota-increase \
      --service-code ec2 \
      --quota-code L-1216C47A \
      --desired-value 20 \
      --region us-east-1
    ```
  - Small increases (8 → 20) are usually approved within 15-30 minutes
- AWS CLI v2 installed and configured locally
- Terraform >= 1.9.0
- Git & GitHub account with Personal Access Token (PAT with `repo` + `write:packages` scopes)
- A domain name with ability to change nameservers
- SSH key pair created in us-east-1

---

## Phase 1: AWS Foundation

### 1.1 Create Terraform Backend (S3 + DynamoDB)

Terraform needs a remote backend to store its state file so your CI/CD pipeline and local machine can share the same infrastructure state.

```bash
# Create S3 bucket for state storage
aws s3api create-bucket \
  --bucket ibrahim-cloud-native-tf-state \
  --region us-east-1

# Enable versioning (recover if state gets corrupted)
aws s3api put-bucket-versioning \
  --bucket ibrahim-cloud-native-tf-state \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for state locking
# Prevents two people from running terraform apply simultaneously
aws dynamodb create-table \
  --table-name ibrahim-cloud-native-tf-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 1.2 Create EC2 Key Pair

```bash
aws ec2 create-key-pair \
  --key-name test \
  --query 'KeyMaterial' \
  --output text \
  --region us-east-1 > test.pem

chmod 400 test.pem
```

### 1.3 Create ECR Repositories

Amazon ECR stores your Docker images privately, right next to EKS for faster pulls and built-in IAM authentication.

```bash
aws ecr create-repository --repository-name frontend --region us-east-1
aws ecr create-repository --repository-name backend --region us-east-1
```

---

## Phase 2: Provision Jenkins Server

### 2.1 Update Terraform Variables

In `Jenkins-Server-TF/variables.tf`, set:

```hcl
variable "instance_type" {
  default = "m7i-flex.large"  # 8GB RAM for Jenkins + SonarQube + Docker
}

variable "key_name" {
  default = "test"  # Must match the key pair created above
}
```

### 2.2 Deploy

```bash
cd Jenkins-Server-TF/
terraform init
terraform plan
terraform apply -auto-approve
```

Note the output: `jenkins_public_ip`, `jenkins_url`, `sonarqube_url`, `ssh_command`.

### 2.3 Immediate Post-Deploy Fixes

> ⚠️ **Fix #1 — EKS IAM Policy:** The Terraform IAM role does NOT include `eks:DescribeClusterVersions`. Run immediately:

```bash
aws iam put-role-policy \
  --role-name jenkins-cloud-native-role \
  --policy-name EKSFullAccess \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"eks:*","Resource":"*"}]}'
```

> ⚠️ **Fix #2 — Credential Override:** The instance profile credentials may be cached. Export credentials directly:

```bash
export AWS_ACCESS_KEY_ID=<your-access-key>
export AWS_SECRET_ACCESS_KEY=<your-secret-key>
export AWS_DEFAULT_REGION=us-east-1
```

### 2.4 Verify Tools (Wait 5 Minutes for User Data)

SSH into the server and verify every tool:

```bash
ssh -i test.pem ubuntu@<jenkins-ip>
sudo su -

jenkins --version
docker --version
terraform --version
aws --version
kubectl version --client
eksctl version
helm version
trivy --version
sonar-scanner --version
```

> ⚠️ **Fix #3 — sonar-scanner may not install:** The user-data script can fail silently during boot. If `sonar-scanner: not found`, install manually:

```bash
cd /tmp
wget -q https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-5.0.1.3006-linux.zip
unzip -o sonar-scanner-cli-5.0.1.3006-linux.zip
sudo mv sonar-scanner-5.0.1.3006-linux /opt/sonar-scanner
sudo ln -sf /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner
sonar-scanner --version
```

---

## Phase 3: Configure Jenkins, SonarQube & Credentials

### 3.1 Unlock Jenkins

Open `http://<jenkins-ip>:8080` in your browser.

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Paste the password, click "Install suggested plugins", create your admin user.

### 3.2 Install Required Plugins

Navigate to Manage Jenkins → Plugins → Available Plugins. Install:

- Docker Pipeline
- Docker Commons
- SonarQube Scanner
- Pipeline: AWS Steps
- Kubernetes CLI

### 3.3 Create Credentials

Navigate to Manage Jenkins → Credentials → System → Global credentials → Add Credentials.

| ID | Kind | Value | Used For |
|---|---|---|---|
| `github-creds` | **Username with password** | GitHub username + PAT | SCM checkout in pipeline jobs |
| `github-token` | Secret text | GitHub PAT | Pipeline git push in Jenkinsfile |
| `ACCOUNT_ID` | Secret text | Your 12-digit AWS Account ID | ECR image URI construction |
| `ECR_REPO1` | Secret text | `frontend` | Frontend ECR repo name |
| `ECR_REPO2` | Secret text | `backend` | Backend ECR repo name |
| `sonar` | Secret text | SonarQube token (from step 3.4) | SonarQube analysis |

> ⚠️ **CRITICAL:** `github-creds` MUST be "Username with password" type. "Secret text" credentials do NOT appear in the SCM credential dropdown when creating pipeline jobs. This caused an empty dropdown during the actual build.

### 3.4 Configure SonarQube

Open `http://<jenkins-ip>:9000`:

1. Login with `admin` / `admin`
2. Change the default password when prompted
3. Generate a token: My Account → Security → Generate Token → Copy the token
4. Add the token as the `sonar` credential in Jenkins (step 3.3)

In Jenkins: Manage Jenkins → System → scroll to **SonarQube Servers**:

- Name: `sonar`
- Server URL: `http://localhost:9000` (same EC2 instance)
- Server authentication token: select the `sonar` credential

### 3.5 Create SonarQube Webhook (CRITICAL)

Without this webhook, the Jenkins Quality Gate stage will **timeout every time**.

In SonarQube: Administration → Configuration → Webhooks → Create:

- Name: `jenkins`
- URL: `http://localhost:8080/sonarqube-webhook/`
- Secret: leave blank
- Save

> **Why localhost?** SonarQube and Jenkins run on the same EC2 instance. localhost avoids routing traffic out to the internet and back.

### 3.6 Configure AWS CLI for Jenkins User

Jenkins pipelines run as the `jenkins` user, which has its own home directory. If you only configure AWS for the `ubuntu` or `root` user, every AWS command in your pipeline fails.

```bash
sudo su - jenkins
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region: us-east-1
# Default output: json
exit
```

Verify:

```bash
sudo su - jenkins -s /bin/bash -c "aws sts get-caller-identity"
```

---

## Phase 4: Create EKS Cluster

### 4.1 Create the Cluster

Run this from the Jenkins server. If running as root, you'll need to copy kubeconfig later (step 4.2). If running as the `jenkins` user, kubeconfig is automatically placed correctly.

```bash
eksctl create cluster \
  --name cloud-native-cluster \
  --region us-east-1 \
  --zones us-east-1a,us-east-1b \
  --nodegroup-name worker-nodes \
  --node-type t3.xlarge \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 3 \
  --managed
```

> **Why t3.xlarge?** t3.small has an ENI pod limit of 11 pods per node. With your app + ArgoCD + monitoring, you exceed this limit and pods get stuck in `Pending`. t3.xlarge supports 58 pods per node and 16GB RAM — enough for everything without scaling issues.

> **Why specify zones?** us-east-1 has 6 AZs but not all support all instance types. Specifying `1a` and `1b` explicitly avoids "unsupported instance type in this AZ" failures 15 minutes into cluster creation.

This takes 15-20 minutes. When it finishes, verify:

```bash
kubectl get nodes
# Should show 2 nodes in Ready status
```

### 4.2 Copy Kubeconfig to Jenkins User

**Only needed if you ran eksctl as root (not as jenkins user):**

```bash
mkdir -p /var/lib/jenkins/.kube
cp /root/.kube/config /var/lib/jenkins/.kube/config
chown -R jenkins:jenkins /var/lib/jenkins/.kube
```

> **Why?** The kubeconfig is saved to the home directory of whichever user runs eksctl. Jenkins pipelines run as the `jenkins` user, which has a different home directory (`/var/lib/jenkins/`). Without copying the kubeconfig, Jenkins pipelines can't talk to the cluster.

### 4.3 Create Namespaces

```bash
kubectl create namespace three-tier
kubectl create namespace monitoring
kubectl create namespace argocd
```

### 4.4 Install EBS CSI Driver

PostgreSQL needs persistent storage. The EBS CSI driver lets Kubernetes create and attach EBS volumes automatically.

```bash
# Associate IAM OIDC provider (required for service account IAM roles)
eksctl utils associate-iam-oidc-provider \
  --cluster cloud-native-cluster \
  --region us-east-1 \
  --approve

# Install EBS CSI driver as an EKS addon
eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster cloud-native-cluster \
  --region us-east-1 \
  --force
```

> **Why?** Without this driver, PostgreSQL PersistentVolumeClaims stay stuck in `Pending` forever. The driver translates Kubernetes storage requests into actual AWS EBS volume creation.

---

## Phase 5: Deploy Database Layer

### 5.1 Clone the Repo on the Jenkins Server

```bash
cd /home/ubuntu
git clone https://github.com/ibrahim-2010/cloud-native-eks.git
cd cloud-native-eks
```

### 5.2 Deploy PostgreSQL and Redis

```bash
kubectl apply -f Kubernetes-Manifests-file/Database/
```

### 5.3 Verify

```bash
kubectl get pods -n three-tier
# postgres and redis should be Running

kubectl get pvc -n three-tier
# postgres-pvc should be Bound

kubectl get svc -n three-tier
# postgres and redis should show ClusterIP
```

> **Why ClusterIP?** PostgreSQL and Redis should never be exposed to the internet. ClusterIP makes them accessible only within the cluster. Other pods connect using Kubernetes DNS names (`postgres.three-tier.svc.cluster.local`).

---

## Phase 6: Build & Deploy Application

### 6.1 Bootstrap — One-Time Manual Build

Before the CI/CD pipeline can work, the first Docker images must exist in ECR.

```bash
# Log into ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS \
  --password-stdin <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com
```

> ⚠️ **Dockerfile Fix:** If the build fails with `npm ci requires package-lock.json`, edit the Dockerfile:
> ```bash
> sed -i 's|npm ci --only=production|npm install --omit=dev|' Application-Code/backend/Dockerfile
> sed -i 's|RUN npm ci|RUN npm install|' Application-Code/frontend/Dockerfile
> ```

**Build and push backend:**

```bash
cd /home/ubuntu/cloud-native-eks/Application-Code/backend
docker build -t <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/backend:1 .
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/backend:1
```

**Build and push frontend:**

```bash
cd /home/ubuntu/cloud-native-eks/Application-Code/frontend
docker build -t <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/frontend:1 .
docker push <ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/frontend:1
```

### 6.2 Update Manifests and Deploy

```bash
cd /home/ubuntu/cloud-native-eks

# Replace placeholder with actual account ID
sed -i 's|<ACCOUNT_ID>|<your-account-id>|g' Kubernetes-Manifests-file/Backend/deployment.yaml
sed -i 's|<ACCOUNT_ID>|<your-account-id>|g' Kubernetes-Manifests-file/Frontend/deployment.yaml

# Fix image tags if they show old build numbers from previous deployments
sed -i 's|backend:[0-9]*|backend:1|' Kubernetes-Manifests-file/Backend/deployment.yaml
sed -i 's|frontend:[0-9]*|frontend:1|' Kubernetes-Manifests-file/Frontend/deployment.yaml

# Deploy
kubectl apply -f Kubernetes-Manifests-file/Backend/
kubectl apply -f Kubernetes-Manifests-file/Frontend/
```

### 6.3 Push to Git IMMEDIATELY

> ⚠️ **CRITICAL:** Push these manifest changes to Git BEFORE setting up ArgoCD. If ArgoCD syncs before you push, it overwrites your working deployments with the placeholder values from Git. All pods go to `InvalidImageName`. This happened during Deployment 1.

```bash
git add -A
git commit -m "fix: set ECR image paths in deployment manifests"
git push origin main
```

### 6.4 Verify

```bash
kubectl get pods -n three-tier
# Should show: postgres (Running), redis (Running), api (Running), frontend (Running)
```

Open the ALB URL in your browser to verify the app is working (ALB won't exist yet — we'll create it in Phase 7).

---

## Phase 7: ALB Ingress Controller

The AWS Load Balancer Controller watches for Ingress resources in Kubernetes and automatically creates an Application Load Balancer in AWS.

### 7.1 Create IAM Policy

```bash
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

### 7.2 Update Policy with Broader Permissions

> ⚠️ **CRITICAL:** The downloaded v2.7.1 policy is missing newer API actions like `elasticloadbalancing:DescribeListenerAttributes` and `ec2:DescribeSecurityGroups`. The Helm chart installs a newer controller version that requires these. Without this update, the ALB will never provision.

```bash
aws iam create-policy-version \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:*",
        "ec2:Describe*",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "iam:CreateServiceLinkedRole",
        "acm:ListCertificates",
        "acm:DescribeCertificate",
        "wafv2:*",
        "waf-regional:*",
        "shield:*",
        "tag:GetResources",
        "tag:TagResources"
      ],
      "Resource": "*"
    }]
  }' --set-as-default
```

### 7.3 Create Service Account and Install Controller

```bash
eksctl create iamserviceaccount \
  --cluster=cloud-native-cluster \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=cloud-native-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

### 7.4 Apply Ingress

**Important:** Install the controller BEFORE applying the ingress. If you apply the ingress first, the controller won't reconcile it and the ADDRESS stays empty.

```bash
kubectl apply -f Kubernetes-Manifests-file/ingress.yaml
```

Wait 1-2 minutes, then verify:

```bash
kubectl get ingress -n three-tier
# ADDRESS should show ALB DNS name like:
# k8s-threetie-cloudnat-xxxxx.us-east-1.elb.amazonaws.com
```

> **If ADDRESS is empty after 3 minutes:**
> ```bash
> # Check controller logs for errors
> kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20
> 
> # If needed, delete and reapply
> kubectl delete ingress cloud-native-ingress -n three-tier
> kubectl apply -f Kubernetes-Manifests-file/ingress.yaml
> ```

Open the ALB URL in your browser — the app should load with green health indicators.

---

## Phase 8: ArgoCD GitOps

### 8.1 Install ArgoCD

```bash
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts
```

> **Why `--server-side --force-conflicts`?** Standard `kubectl apply` fails because ArgoCD CRD annotations exceed the 262144 byte limit. Server-side apply avoids this.

### 8.2 Expose and Access ArgoCD

```bash
# Expose via LoadBalancer
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# Get the admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Get the URL
kubectl get svc argocd-server -n argocd
```

Open `https://<EXTERNAL-IP>` in your browser (accept the certificate warning). Login with:
- Username: `admin`
- Password: output from the command above

### 8.3 Connect Your GitHub Repository

In ArgoCD UI: Settings (gear icon) → Repositories → Connect Repo Using HTTPS:

- Repository URL: `https://github.com/ibrahim-2010/cloud-native-eks.git`
- Username: your GitHub username
- Password: your GitHub PAT
- Click Connect

### 8.4 Create Applications

Go to Applications → New App. Create these 3 applications:

**App 1 — Database:**
| Field | Value |
|-------|-------|
| Application Name | `three-tier-database` |
| Project | `default` |
| Sync Policy | `Automatic` (check Prune Resources + Self Heal) |
| Repository URL | Select your repo |
| Revision | `main` |
| Path | `Kubernetes-Manifests-file/Database` |
| Cluster URL | `https://kubernetes.default.svc` |
| Namespace | `three-tier` |

**App 2 — Backend:**
| Field | Value |
|-------|-------|
| Application Name | `three-tier-backend` |
| Path | `Kubernetes-Manifests-file/Backend` |
| *(all other fields same as above)* | |

**App 3 — Frontend:**
| Field | Value |
|-------|-------|
| Application Name | `three-tier-frontend` |
| Path | `Kubernetes-Manifests-file/Frontend` |
| *(all other fields same as above)* | |

All 3 apps should show **Healthy** and **Synced** within a minute.

> **What is Self Heal?** If someone manually runs `kubectl scale deployment api --replicas=5`, ArgoCD detects the drift from Git (which says 1 replica) and reverts it back within 30 seconds. Git is the single source of truth.

---

## Phase 9: Jenkins CI/CD Pipelines

### 9.1 Create Pipeline Jobs

In Jenkins Dashboard → New Item → Pipeline:

**Backend Pipeline:**
- Name: `three-tier-backend`
- Pipeline Definition: Pipeline script from SCM
- SCM: Git
- Repository URL: `https://github.com/ibrahim-2010/cloud-native-eks.git`
- Credentials: select `github-creds` (Username with password)
- Branch: `*/main`
- Script Path: `Jenkins-Pipeline-Code/Jenkinsfile-Backend`
- Save

**Frontend Pipeline:**
- Same settings but:
- Name: `three-tier-frontend`
- Script Path: `Jenkins-Pipeline-Code/Jenkinsfile-Frontend`

### 9.2 Verify Jenkinsfile Paths

The `dir()` paths in the Jenkinsfiles must match your repo structure. If the repo is flat (no nesting), paths should be `Application-Code/backend` not `cloud-native-eks/Application-Code/backend`.

```bash
grep "dir(" Jenkins-Pipeline-Code/Jenkinsfile-Backend
```

### 9.3 Run the Pipelines

Click `Build Now` on `three-tier-backend`. The 9 stages should execute:

1. **Cleanup Workspace** — wipes workspace
2. **Checkout Code** — clones from GitHub
3. **SonarQube Analysis** — scans code quality
4. **Quality Gate** — waits for SonarQube verdict (requires webhook)
5. **Trivy Filesystem Scan** — scans source code for CVEs
6. **Docker Build & Tag** — builds container image
7. **Trivy Image Scan** — scans built image for CVEs
8. **Push to ECR** — pushes to private registry
9. **Update Kubernetes Manifest** — sed updates image tag, git push triggers ArgoCD

Repeat for `three-tier-frontend`.

After both pass, the full automated loop is active:
```
Code Push → Jenkins → SonarQube → Trivy → Docker → ECR → Git → ArgoCD → EKS
```

---

## Phase 10: Monitoring Stack

### 10.1 Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.storageSpec=null \
  --set alertmanager.alertmanagerSpec.storage=null \
  --timeout 10m
```

> **Why `storageSpec=null`?** By default, the chart creates PersistentVolumeClaims. If the EBS CSI driver has issues, pods get stuck in Pending. Setting storage to null uses emptyDir instead. For a portfolio project this is fine.

> **With t3.xlarge nodes:** No need for reduced resource settings. Everything fits comfortably on 2 nodes.

### 10.2 Access Grafana

```bash
# Expose via LoadBalancer
kubectl patch svc monitoring-grafana -n monitoring \
  -p '{"spec": {"type": "LoadBalancer"}}'

# Get credentials
kubectl get secret monitoring-grafana -n monitoring \
  -o jsonpath="{.data.admin-user}" | base64 -d && echo

kubectl get secret monitoring-grafana -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 -d && echo

# Get URL
kubectl get svc monitoring-grafana -n monitoring
```

Open the EXTERNAL-IP in your browser and login with the credentials above.

### 10.3 Apply Custom Alerts

```bash
kubectl apply -f Kubernetes-Manifests-file/monitoring-alerts.yaml
```

This creates 5 custom PrometheusRule alerts:

| Alert | Fires When | Severity |
|-------|-----------|----------|
| PodDown | Replicas below desired in three-tier | Critical |
| HighCPUUsage | CPU > 80% for 2 minutes | Warning |
| PodCrashLooping | Repeated restarts over 15 minutes | Critical |
| PostgreSQLDown | Zero PostgreSQL pods available | Critical |
| RedisDown | Zero Redis pods available | Critical |

### 10.4 Verify in Grafana

Navigate to Dashboards → Browse → "Kubernetes / Compute Resources / Namespace (Pods)" → select namespace `three-tier`. You should see CPU and memory graphs for all your pods.

---

## Phase 11: Route 53 & Domain

### 11.1 Create Hosted Zone

```bash
aws route53 create-hosted-zone \
  --name platinum-consults.com \
  --caller-reference $(date +%s)
```

Copy the 4 NS (Name Server) records from the output. They look like:
- `ns-1221.awsdns-24.org`
- `ns-408.awsdns-51.com`
- `ns-917.awsdns-50.net`
- `ns-1993.awsdns-57.co.uk`

### 11.2 Update Nameservers at Your Domain Registrar

For Turbify:

1. Sign in to [Turbify Domain Control Panel](https://turbify.com/services)
2. Find your domain and click to manage it
3. Unlock the domain (look for lock/unlock option)
4. Scroll to **Name Servers** → Click **Change**
5. Enter the 4 AWS NS records from step 11.1
6. Click **Update**

Propagation: usually 5-30 minutes, can take up to 72 hours.

### 11.3 Create Alias Record (AWS Console)

1. AWS Console → Route 53 → Hosted Zones → platinum-consults.com → **Create Record**
2. Record name: leave blank (root domain)
3. Record type: **A**
4. Toggle **Alias**: ON
5. Route traffic to: **Alias to Application and Classic Load Balancer**
6. Region: **US East (N. Virginia) [us-east-1]**
7. Select your ALB from the dropdown (starts with `k8s-threetie-cloudnat`)
8. Click **Create records**

### 11.4 Verify

After DNS propagation (1-5 minutes), open in your browser:

```
http://platinum-consults.com
```

The app should load with all green health indicators.

---

## Cleanup

> ⚠️ **CRITICAL:** Run cleanup in this order to avoid orphan resources and surprise charges.

```bash
# 1. Delete ArgoCD applications first
kubectl delete applications --all -n argocd

# 2. Delete monitoring stack
helm uninstall monitoring -n monitoring

# 3. Delete ArgoCD
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 4. Delete EKS cluster (takes 10-15 minutes)
eksctl delete cluster --name cloud-native-cluster --region us-east-1

# 5. Delete ECR repositories
aws ecr delete-repository --repository-name frontend --region us-east-1 --force
aws ecr delete-repository --repository-name backend --region us-east-1 --force

# 6. Delete LB Controller IAM policy (delete old versions first if needed)
aws iam list-policy-versions \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --query "Versions[?IsDefaultVersion==\`false\`].VersionId" --output text | \
  xargs -n1 aws iam delete-policy-version \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --version-id

aws iam delete-policy \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy

# 7. Destroy Jenkins server via Terraform
cd Jenkins-Server-TF/
terraform destroy -auto-approve

# 8. Optional: Delete Terraform state backend
aws s3 rb s3://ibrahim-cloud-native-tf-state --force
aws dynamodb delete-table --table-name ibrahim-cloud-native-tf-lock --region us-east-1
```

### Manual Verification in AWS Console

After all commands complete, check:

- **EC2:** No running instances, no orphan load balancers
- **EBS:** No orphan volumes
- **CloudFormation:** All stacks deleted
- **Elastic IPs:** None allocated
- **Route 53:** Domain records (keep if you want the domain)
- **IAM:** jenkins-cloud-native-role and instance profile removed by Terraform

---

*Ibrahim | [github.com/ibrahim-2010/cloud-native-eks](https://github.com/ibrahim-2010/cloud-native-eks) | [platinum-consults.com](http://platinum-consults.com)*
