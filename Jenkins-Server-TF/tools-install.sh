#!/bin/bash
set -euo pipefail
# =============================================================================
# Tools Installation Script for Jenkins Server (Ubuntu 22.04)
#
# FIXES APPLIED FROM DEPLOYMENT 3:
#   1. Uses jenkins-plugin-manager JAR (from GitHub, not Jenkins mirrors)
#      for reliable plugin installation with dependency resolution
#   2. docker-workflow instead of docker-pipeline (renamed plugin)
#   3. SonarQube removed from JCasC YAML (sonarGlobalConfiguration not 
#      recognized — configure via setup-jcasc.sh API call instead)
#   4. systemd override for JCasC (not /etc/default/jenkins)
#   5. Jenkins stopped before plugin install, started AFTER everything ready
#   6. sonar-scanner installed with verification
#   7. setup-jcasc.sh downloaded from GitHub repo
#
# After boot, run: sudo bash /opt/setup-jcasc.sh
# =============================================================================

exec > /var/log/tools-install.log 2>&1
echo "========== Starting tools installation $(date) =========="

# ─── System Update ───────────────────────────────────────────────────────────
echo "===> Updating system"
sudo apt update -y
sudo apt install -y fontconfig openjdk-21-jdk curl gnupg unzip wget lsb-release apt-transport-https

# ─── Jenkins ─────────────────────────────────────────────────────────────────
echo "===> Installing Jenkins"
sudo mkdir -p /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
  https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y jenkins

# STOP Jenkins — configure everything before first real boot
sudo systemctl stop jenkins
sudo systemctl disable jenkins
sleep 5
echo "  Jenkins installed and stopped"

# ─── Docker ──────────────────────────────────────────────────────────────────
echo "===> Installing Docker"
sudo apt install -y docker.io
sudo usermod -aG docker jenkins
sudo usermod -aG docker ubuntu
sudo systemctl enable docker
sudo systemctl restart docker
sudo chmod 777 /var/run/docker.sock

# ─── SonarQube (Docker container) ────────────────────────────────────────────
echo "===> Starting SonarQube container"
docker run -d --name sonar --restart unless-stopped \
  -p 9000:9000 \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  sonarqube:lts-community

# ─── Sonar-Scanner ───────────────────────────────────────────────────────────
echo "===> Installing Sonar-Scanner"
cd /tmp
wget -q https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-5.0.1.3006-linux.zip
unzip -o sonar-scanner-cli-5.0.1.3006-linux.zip
sudo mv sonar-scanner-5.0.1.3006-linux /opt/sonar-scanner
sudo ln -sf /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner
rm -f sonar-scanner-cli-5.0.1.3006-linux.zip
# Verify
if sonar-scanner --version 2>&1 | grep -q "SonarScanner"; then
  echo "  sonar-scanner installed successfully"
else
  echo "  WARNING: sonar-scanner installation may have failed"
fi

# ─── AWS CLI ─────────────────────────────────────────────────────────────────
echo "===> Installing AWS CLI"
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -o /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install --update
rm -rf /tmp/awscliv2.zip /tmp/aws

# ─── kubectl ─────────────────────────────────────────────────────────────────
echo "===> Installing kubectl"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

# ─── eksctl ──────────────────────────────────────────────────────────────────
echo "===> Installing eksctl"
ARCH=amd64 && PLATFORM=$(uname -s)_${ARCH}
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz"
tar -xzf "eksctl_${PLATFORM}.tar.gz" -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
rm -f "eksctl_${PLATFORM}.tar.gz"

# ─── Terraform ───────────────────────────────────────────────────────────────
echo "===> Installing Terraform"
wget -O- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update -y && sudo apt install -y terraform

# ─── Trivy ───────────────────────────────────────────────────────────────────
echo "===> Installing Trivy"
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] \
  https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt update -y && sudo apt install -y trivy

# ─── Helm ────────────────────────────────────────────────────────────────────
echo "===> Installing Helm"
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ══════════════════════════════════════════════════════════════════════════════
#  JENKINS PLUGIN INSTALLATION
#  Uses jenkins-plugin-manager from GitHub (NOT Jenkins mirrors)
#  This tool resolves ALL dependencies automatically
# ══════════════════════════════════════════════════════════════════════════════

echo "===> Downloading Jenkins Plugin Manager"
PLUGIN_MGR_VERSION="2.13.2"
wget -q "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${PLUGIN_MGR_VERSION}/jenkins-plugin-manager-${PLUGIN_MGR_VERSION}.jar" \
  -O /tmp/jenkins-plugin-manager.jar

echo "===> Installing Jenkins plugins (with dependency resolution)"
# Retry up to 3 times in case of transient mirror issues
for attempt in 1 2 3; do
  echo "  Attempt $attempt of 3..."
  java -jar /tmp/jenkins-plugin-manager.jar \
    --war /usr/share/java/jenkins.war \
    --plugin-download-directory /var/lib/jenkins/plugins \
    --plugins \
    configuration-as-code \
    job-dsl \
    workflow-aggregator \
    pipeline-stage-view \
    git \
    docker-workflow \
    docker-commons \
    sonar \
    pipeline-aws \
    kubernetes-cli \
    credentials-binding \
    ws-cleanup \
    timestamper \
    && break || echo "  Attempt $attempt failed, retrying in 30s..." && sleep 30
done

# Verify plugins were downloaded
PLUGIN_COUNT=$(find /var/lib/jenkins/plugins -name "*.jpi" -o -name "*.hpi" 2>/dev/null | wc -l)
echo "  Plugins downloaded: $PLUGIN_COUNT"
if [ "$PLUGIN_COUNT" -lt 10 ]; then
  echo "  WARNING: Plugin installation may have failed. Check mirror status."
  echo "  Test: curl -s -o /dev/null -w '%{http_code}' https://updates.jenkins.io/latest/configuration-as-code.hpi"
fi

sudo chown -R jenkins:jenkins /var/lib/jenkins/plugins/

# ══════════════════════════════════════════════════════════════════════════════
#  JCASC CONFIGURATION
#  NOTE: SonarQube is NOT configured in JCasC because the attribute name
#  (sonarGlobalConfiguration) is not recognized by JCasC in newer Jenkins.
#  SonarQube is configured via API in setup-jcasc.sh instead.
# ══════════════════════════════════════════════════════════════════════════════

echo "===> Setting up JCasC"
sudo mkdir -p /var/lib/jenkins/casc_configs

# Get the public IP for Jenkins URL
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "localhost")

cat > /tmp/jenkins-casc.yaml << 'CASC_EOF'
jenkins:
  systemMessage: "Cloud-Native EKS Project — Configured via JCasC"
  numExecutors: 2
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: "admin"
          password: "${JENKINS_ADMIN_PASSWORD:-admin123}"
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false

unclassified:
  location:
    url: "JENKINS_URL_PLACEHOLDER"

credentials:
  system:
    domainCredentials:
      - credentials:
          - usernamePassword:
              scope: GLOBAL
              id: "github-creds"
              description: "GitHub credentials for SCM checkout"
              username: "${GITHUB_USERNAME}"
              password: "${GITHUB_PAT}"
          - string:
              scope: GLOBAL
              id: "github-token"
              description: "GitHub PAT for pipeline git push"
              secret: "${GITHUB_PAT}"
          - string:
              scope: GLOBAL
              id: "ACCOUNT_ID"
              description: "AWS Account ID"
              secret: "${AWS_ACCOUNT_ID}"
          - string:
              scope: GLOBAL
              id: "ECR_REPO1"
              description: "Frontend ECR repository name"
              secret: "frontend"
          - string:
              scope: GLOBAL
              id: "ECR_REPO2"
              description: "Backend ECR repository name"
              secret: "backend"
          - string:
              scope: GLOBAL
              id: "sonar"
              description: "SonarQube authentication token"
              secret: "${SONARQUBE_TOKEN}"

jobs:
  - script: >
      pipelineJob('three-tier-backend') {
        description('Backend CI/CD Pipeline')
        definition {
          cpsScm {
            scm {
              git {
                remote {
                  url('https://github.com/ibrahim-2010/cloud-native-eks.git')
                  credentials('github-creds')
                }
                branches('*/main')
              }
            }
            scriptPath('Jenkins-Pipeline-Code/Jenkinsfile-Backend')
          }
        }
      }
  - script: >
      pipelineJob('three-tier-frontend') {
        description('Frontend CI/CD Pipeline')
        definition {
          cpsScm {
            scm {
              git {
                remote {
                  url('https://github.com/ibrahim-2010/cloud-native-eks.git')
                  credentials('github-creds')
                }
                branches('*/main')
              }
            }
            scriptPath('Jenkins-Pipeline-Code/Jenkinsfile-Frontend')
          }
        }
      }
CASC_EOF

# Replace the URL placeholder with actual IP
sed -i "s|JENKINS_URL_PLACEHOLDER|http://${PUBLIC_IP}:8080/|" /tmp/jenkins-casc.yaml

sudo cp /tmp/jenkins-casc.yaml /var/lib/jenkins/casc_configs/jenkins.yaml
sudo chown -R jenkins:jenkins /var/lib/jenkins/casc_configs

# ─── Configure systemd override ─────────────────────────────────────────────
echo "===> Configuring systemd override for JCasC"
sudo mkdir -p /etc/systemd/system/jenkins.service.d

cat > /tmp/jenkins-override.conf << 'OVERRIDE_EOF'
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Dcasc.jenkins.config=/var/lib/jenkins/casc_configs/jenkins.yaml"
Environment="CASC_JENKINS_CONFIG=/var/lib/jenkins/casc_configs/jenkins.yaml"
OVERRIDE_EOF

sudo cp /tmp/jenkins-override.conf /etc/systemd/system/jenkins.service.d/override.conf
sudo systemctl daemon-reload

# ─── Download setup-jcasc.sh ─────────────────────────────────────────────────
echo "===> Downloading setup-jcasc.sh"
wget -q -O /opt/setup-jcasc.sh \
  "https://raw.githubusercontent.com/ibrahim-2010/cloud-native-eks/main/Jenkins-Server-TF/jcasc/setup-jcasc.sh" \
  || echo "  WARNING: Could not download setup-jcasc.sh — download manually after boot"
sudo chmod +x /opt/setup-jcasc.sh 2>/dev/null || true

# ─── Start Jenkins ───────────────────────────────────────────────────────────
echo "===> Starting Jenkins with JCasC and pre-installed plugins"
sudo systemctl enable jenkins
sudo systemctl start jenkins

# ─── Verify all tools ────────────────────────────────────────────────────────
echo ""
echo "========== Installation Complete $(date) =========="
echo ""
echo "Tool Versions:"
echo "  Jenkins:        $(jenkins --version 2>/dev/null || echo 'check manually')"
echo "  Docker:         $(docker --version 2>/dev/null | awk '{print $3}' || echo 'check manually')"
echo "  Terraform:      $(terraform --version 2>/dev/null | head -1 || echo 'check manually')"
echo "  AWS CLI:        $(aws --version 2>/dev/null | awk '{print $1}' || echo 'check manually')"
echo "  kubectl:        $(kubectl version --client --short 2>/dev/null || echo 'check manually')"
echo "  eksctl:         $(eksctl version 2>/dev/null || echo 'check manually')"
echo "  Helm:           $(helm version --short 2>/dev/null || echo 'check manually')"
echo "  Trivy:          $(trivy --version 2>/dev/null | head -1 || echo 'check manually')"
echo "  sonar-scanner:  $(sonar-scanner --version 2>&1 | grep SonarScanner || echo 'check manually')"
echo "  Plugins:        ${PLUGIN_COUNT} downloaded"
echo ""
echo "NEXT STEPS:"
echo "  1. SSH into this server"
echo "  2. Run: sudo bash /opt/setup-jcasc.sh"
echo "  3. Jenkins auto-configures credentials, jobs, and SonarQube"
