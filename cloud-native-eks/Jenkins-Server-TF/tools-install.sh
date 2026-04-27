#!/bin/bash
# =============================================================================
# Tools Installation Script for Jenkins Server (Ubuntu 22.04)
# Installs: Java, Jenkins, Docker, SonarQube, AWS CLI, kubectl, eksctl,
#           Terraform, Trivy, Helm
# =============================================================================

# ─── Java 17 ─────────────────────────────────────────────────────────────────
echo "===> Installing Java 17"
sudo apt update -y
sudo apt install -y fontconfig openjdk-21-jdk curl gnupg
java --version

# ─── Jenkins (2026 GPG key) ──────────────────────────────────────────────────
echo "===> Installing Jenkins"
sudo mkdir -p /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key

echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y jenkins

sudo systemctl daemon-reload
sudo systemctl enable jenkins
sudo systemctl start jenkins

# ─── Docker ──────────────────────────────────────────────────────────────────
echo "===> Installing Docker"
sudo apt update -y
sudo apt install -y docker.io
sudo usermod -aG docker jenkins
sudo usermod -aG docker ubuntu
sudo systemctl restart docker
sudo chmod 777 /var/run/docker.sock

# ─── SonarQube (Docker container) ────────────────────────────────────────────
echo "===> Starting SonarQube container"
docker run -d --name sonar -p 9000:9000 sonarqube:lts-community

# ─── AWS CLI ─────────────────────────────────────────────────────────────────
echo "===> Installing AWS CLI"
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo apt install -y unzip
unzip -o awscliv2.zip
sudo ./aws/install
rm -rf awscliv2.zip aws/

# ─── kubectl ─────────────────────────────────────────────────────────────────
echo "===> Installing kubectl"
sudo curl -LO "https://dl.k8s.io/release/v1.28.4/bin/linux/amd64/kubectl"
sudo chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client

# ─── eksctl ──────────────────────────────────────────────────────────────────
echo "===> Installing eksctl"
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
eksctl version

# ─── Terraform ───────────────────────────────────────────────────────────────
echo "===> Installing Terraform"
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update -y
sudo apt install -y terraform

# ─── Trivy ───────────────────────────────────────────────────────────────────
echo "===> Installing Trivy"
sudo apt-get install -y wget apt-transport-https gnupg lsb-release
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
echo deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main | sudo tee -a /etc/apt/sources.list.d/trivy.list
sudo apt update -y
sudo apt install -y trivy

# ─── Helm ────────────────────────────────────────────────────────────────────
echo "===> Installing Helm"
sudo snap install helm --classic

echo "===> All tools installed successfully!"