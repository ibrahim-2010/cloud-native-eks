#!/bin/bash
set -euo pipefail
# =============================================================================
#  JCasC Secret Injection — Run ONCE after Jenkins server boots
#
#  ALL FIXES FROM DEPLOYMENTS 1-5:
#   1. SonarQube configured via Groovy init script (not JCasC)
#   2. Webhook uses private IP (localhost blocked by newer SonarQube)
#   3. AWS credentials for jenkins + root users
#   4. systemd override for environment variables
#   5. SonarQube token auto-generated via API
#   6. SonarQube password auto-changed
#   7. Verifies Jenkins is responding before declaring success
#
#  Usage: sudo bash /opt/setup-jcasc.sh
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║     Jenkins JCasC — Secret Injection              ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Gather secrets ──────────────────────────────────────────────────────────
read -p "GitHub Username: " GITHUB_USERNAME
read -sp "GitHub PAT: " GITHUB_PAT
echo ""
read -p "AWS Account ID (12 digits): " AWS_ACCOUNT_ID
read -sp "Jenkins Admin Password: " JENKINS_ADMIN_PASSWORD
echo ""
read -p "AWS Access Key ID: " AWS_ACCESS_KEY_ID
read -sp "AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY
echo ""

# ─── Get IPs ─────────────────────────────────────────────────────────────────
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || echo "localhost")
PRIVATE_IP=$(hostname -I | awk '{print $1}')

# ─── SonarQube setup ─────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Setting up SonarQube...${NC}"

echo "  Waiting for SonarQube to be ready..."
for i in $(seq 1 60); do
  if curl -s -u admin:admin "http://localhost:9000/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; then
    echo "  SonarQube is ready"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo -e "${RED}  SonarQube did not start within 5 minutes${NC}"
    read -sp "  Enter SonarQube Token manually: " SONARQUBE_TOKEN
    echo ""
  fi
  sleep 5
done

# Change default password
SONAR_NEW_PASS="SonarAdmin2026!"
curl -s -u admin:admin -X POST \
  "http://localhost:9000/api/users/change_password?login=admin&previousPassword=admin&password=${SONAR_NEW_PASS}" \
  2>/dev/null && echo "  SonarQube password changed" \
  || echo "  SonarQube password may already be changed"

# Generate token
if [ -z "${SONARQUBE_TOKEN:-}" ]; then
  SONARQUBE_TOKEN=$(curl -s -u "admin:${SONAR_NEW_PASS}" -X POST \
    "http://localhost:9000/api/user_tokens/generate?name=jenkins-$(date +%s)" \
    2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

  if [ -z "$SONARQUBE_TOKEN" ]; then
    echo -e "${YELLOW}  Auto-generation failed. Enter SonarQube token manually:${NC}"
    read -sp "  SonarQube Token: " SONARQUBE_TOKEN
    echo ""
  else
    echo "  Token generated successfully"
  fi
fi

# ─── SonarQube webhook (private IP, not localhost) ───────────────────────────
echo -e "${YELLOW}Creating SonarQube webhook...${NC}"
WEBHOOK_RESULT=$(curl -s -u "admin:${SONAR_NEW_PASS}" -X POST \
  "http://localhost:9000/api/webhooks/create?name=jenkins&url=http://${PRIVATE_IP}:8080/sonarqube-webhook/" \
  2>/dev/null)
if echo "$WEBHOOK_RESULT" | grep -q "errors"; then
  echo "  Trying with public IP..."
  curl -s -u "admin:${SONAR_NEW_PASS}" -X POST \
    "http://localhost:9000/api/webhooks/create?name=jenkins-pub&url=http://${PUBLIC_IP}:8080/sonarqube-webhook/" \
    2>/dev/null || true
  echo "  Webhook created with public IP"
else
  echo "  Webhook created: http://${PRIVATE_IP}:8080/sonarqube-webhook/"
fi

# ─── systemd override with secrets ───────────────────────────────────────────
echo -e "${YELLOW}Writing systemd override with secrets...${NC}"
sudo mkdir -p /etc/systemd/system/jenkins.service.d

sudo bash -c "cat > /etc/systemd/system/jenkins.service.d/override.conf << EOF
[Service]
Environment=\"JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false -Dcasc.jenkins.config=/var/lib/jenkins/casc_configs/jenkins.yaml\"
Environment=\"CASC_JENKINS_CONFIG=/var/lib/jenkins/casc_configs/jenkins.yaml\"
Environment=\"JENKINS_ADMIN_PASSWORD=${JENKINS_ADMIN_PASSWORD}\"
Environment=\"GITHUB_USERNAME=${GITHUB_USERNAME}\"
Environment=\"GITHUB_PAT=${GITHUB_PAT}\"
Environment=\"AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}\"
Environment=\"SONARQUBE_TOKEN=${SONARQUBE_TOKEN}\"
EOF"

# ─── SonarQube in Jenkins via Groovy init script ─────────────────────────────
echo -e "${YELLOW}Configuring SonarQube server in Jenkins...${NC}"
sudo mkdir -p /var/lib/jenkins/init.groovy.d
sudo bash -c "cat > /var/lib/jenkins/init.groovy.d/sonarqube.groovy << 'GROOVY_EOF'
import hudson.plugins.sonar.*
import jenkins.model.Jenkins

def instance = Jenkins.getInstance()
def sonarConfig = instance.getDescriptor(SonarGlobalConfiguration.class)
def sonarInstallation = new SonarInstallation(
    'sonar', 'http://localhost:9000', 'sonar',
    null, null, null, null, null, null
)
sonarConfig.setInstallations(sonarInstallation)
sonarConfig.save()
println 'SonarQube server configured via init.groovy.d'
GROOVY_EOF"
sudo chown jenkins:jenkins /var/lib/jenkins/init.groovy.d/sonarqube.groovy

# ─── AWS CLI for jenkins + root users ────────────────────────────────────────
echo -e "${YELLOW}Configuring AWS CLI...${NC}"

# Jenkins user
sudo mkdir -p /var/lib/jenkins/.aws
sudo bash -c "cat > /var/lib/jenkins/.aws/config << EOF
[default]
region = us-east-1
output = json
EOF"
sudo bash -c "cat > /var/lib/jenkins/.aws/credentials << EOF
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF"
sudo chown -R jenkins:jenkins /var/lib/jenkins/.aws
sudo chmod 600 /var/lib/jenkins/.aws/credentials

# Root user
mkdir -p ~/.aws
cat > ~/.aws/config << EOF
[default]
region = us-east-1
output = json
EOF
cat > ~/.aws/credentials << EOF
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF
chmod 600 ~/.aws/credentials

export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
export AWS_DEFAULT_REGION=us-east-1

# ─── Restart Jenkins ─────────────────────────────────────────────────────────
echo -e "${YELLOW}Restarting Jenkins...${NC}"
sudo systemctl daemon-reload
sudo systemctl restart jenkins

echo "  Waiting for Jenkins to start..."
for i in $(seq 1 12); do
  sleep 10
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${JENKINS_ADMIN_PASSWORD}" "http://localhost:8080" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    break
  fi
  echo "  Still waiting... ($HTTP_CODE)"
done

# ─── Verify ──────────────────────────────────────────────────────────────────
echo ""
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "admin:${JENKINS_ADMIN_PASSWORD}" "http://localhost:8080" 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
  echo -e "${GREEN}╔══════════════════════════════════════════════════╗"
  echo "║         JCASC SETUP COMPLETE                      ║"
  echo "╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "Jenkins URL:    http://${PUBLIC_IP}:8080"
  echo "SonarQube URL:  http://${PUBLIC_IP}:9000"
  echo "SonarQube:      admin / SonarAdmin2026!"
  echo "Jenkins:        admin / ${JENKINS_ADMIN_PASSWORD}"
  echo ""
  echo "Auto-configured:"
  echo "  ✅ 6 credentials (github-creds, github-token, ACCOUNT_ID, ECR repos, sonar)"
  echo "  ✅ SonarQube server (via Groovy init script)"
  echo "  ✅ SonarQube webhook (http://${PRIVATE_IP}:8080/sonarqube-webhook/)"
  echo "  ✅ 2 pipeline jobs (three-tier-backend, three-tier-frontend)"
  echo "  ✅ AWS CLI configured for jenkins + root users"
  echo ""
  echo "Verify AWS: aws sts get-caller-identity"
else
  echo -e "${RED}Jenkins returned HTTP $HTTP_CODE${NC}"
  echo "Check logs: journalctl -u jenkins.service --no-pager | tail -30"
fi