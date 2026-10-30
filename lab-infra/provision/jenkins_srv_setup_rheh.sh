#!/usr/bin/env bash

# global variables
LOG_FILE="/var/log/jenkins-bootstrap.log"

JAVA_VERSION="25"

JENKINS_PLUGIN_MANAGER_VERSION="2.15.0"
JENKINS_PLUGINS=(
  workflow-aggregator
  git
  credentials
  credentials-binding
  kubernetes
  pipeline-graph-view
  timestamper
  warnings-ng
  junit
  ws-cleanup
  configuration-as-code
  job-dsl
)

set -euo pipefail
# -e exit immediately if any command returns a non-zero status
# -u treat unset variables as an error and exit immediately
# -o pipefail the return value of a pipeline is the status of the last command to exit with a non-zero status
# -x print each command before executing it (useful for debugging)

exec > >(tee -a "$LOG_FILE") 2>&1
# exec command replaces the current shell process with the command that follows, so the redirection applies to the entire script from that point onward
# ``> >(tee -a "$LOG_FILE")` uses process substitution: the shell runs `tee -a "$LOG_FILE"` as a background process, and the script’s standard output is sent into it.
# -a option tells tee to append to the log file instead of overwriting it
# 2>&1 then duplicates standard error to the same destination as standard output, ensuring both normal logs and error messages go to the same place.

# In effect, this makes the script log everything it prints to a file while still displaying it live in the console. That is very useful for installation or setup scripts, because it preserves a complete record of what happened without losing real-time visibility.

echo "=== Jenkins bootstrap started ==="
date

echo "=== Updating system packages ==="
sudo dnf upgrade --refresh -y

echo "=== Installing base packages ==="
sudo dnf install -y \
  java-$JAVA_VERSION-openjdk \
  fontconfig \
  git \
  curl \
  wget \
  git

echo "=== Verifying key tools ==="
java -version
git --version
curl --version
wget --version

echo "=== Installing Jenkins LTS ==="

echo "Importing the Jenkins 2026 signing key..."
sudo rpm --import \
  https://pkg.jenkins.io/redhat-stable/jenkins.io-2026.key

echo "Adding the official Jenkins LTS repository..."
sudo curl -fsSL \
  -o /etc/yum.repos.d/jenkins.repo \
  https://pkg.jenkins.io/redhat-stable/jenkins.repo

echo "Refreshing the repository metadata..."
sudo dnf makecache --refresh -y

echo "Verifying that Jenkins is available..."
# dnf repoquery --available -y jenkins
dnf info jenkins
# dnf --showduplicates list jenkins

echo "Installing Jenkins LTS..."
sudo dnf install -y jenkins

# echo "Inspecting the installed package..."
# rpm -ql jenkins | head -40

echo "=== Installing Jenkins plugins (offline) ==="

JENKINS_PLUGIN_MANAGER_JAR="/usr/local/bin/jenkins-plugin-manager.jar"
JENKINS_WAR="/usr/share/java/jenkins.war"
JENKINS_PLUGIN_FILE="$(mktemp).txt"

printf "%s\n" "${JENKINS_PLUGINS[@]}" | tee "$JENKINS_PLUGIN_FILE" > /dev/null

# Stop Jenkins before modifying plugin directory
sudo systemctl stop jenkins || true

echo "Downloading Jenkins Plugin Manager Tool..."
sudo curl -fL \
  -o "$JENKINS_PLUGIN_MANAGER_JAR" \
  https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${JENKINS_PLUGIN_MANAGER_VERSION}/jenkins-plugin-manager-${JENKINS_PLUGIN_MANAGER_VERSION}.jar

# verify
# java -jar "$JENKINS_PLUGIN_MANAGER_JAR" --version

echo "Installing plugins into /var/lib/jenkins/plugins..."

sudo mkdir -p /var/lib/jenkins/plugins
sudo java -jar "$JENKINS_PLUGIN_MANAGER_JAR" \
  --war "$JENKINS_WAR" \
  --plugin-file "$JENKINS_PLUGIN_FILE" \
  --plugin-download-directory /var/lib/jenkins/plugins

sudo rm -f "$JENKINS_PLUGIN_FILE"

# fix ownership of the plugin directory
sudo chown -R jenkins:jenkins /var/lib/jenkins/plugins

echo "=== Plugins installed successfully ==="

echo "=== Enabling and starting Jenkins ==="
sudo systemctl enable --now jenkins

echo "Checking Jenkins service status..."
sudo systemctl status jenkins --no-pager
# sudo ss -lntp | grep ':8080'
# curl -I http://127.0.0.1:8080/login


echo "=== Hardening firewall ==="

# echo "Verifying the interfaces..."
# ip -br addr show eth0
# ip -br addr show eth1
# addr show specifically tells ip to display the addresses attached to network interfaces
# -br, -brief: Print  only basic information in a tabular format for better readability. This option is currently only
# supported by ip addr show , ip link show & ip neigh show commands.

echo "Creating a dedicated firewall zone and allowing Jenkins to access 8080..."
sudo firewall-cmd --permanent --new-zone=lab

sudo firewall-cmd --permanent \
  --zone=lab \
  --add-port=8080/tcp

echo "Getting a connection name and IP address of the private interface..."
# for Vagrant VMs of our platform it's host-only network interface (eth1)
ETH1_CONNECTION_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | grep eth1 | cut -d: -f1)
ETH1_IP=$(ip -br addr show eth1 | awk '{print $3}' | cut -d/ -f1)

echo "Assigning the private interface to the lab zone..."
sudo nmcli connection modify "$ETH1_CONNECTION_NAME" connection.zone lab

echo "Applying the firewall changes..."
sudo firewall-cmd --reload
sudo firewall-cmd --get-active-zones
sudo firewall-cmd --permanent --zone=lab --list-ports
# eth1 and 8080/tcp should now be assigned to the lab zone

echo "Restricting the Jenkins listener..."
sudo mkdir -p /etc/systemd/system/jenkins.service.d/
sudo tee /etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
TimeoutStartSec=300
Environment="JENKINS_LISTEN_ADDRESS=$ETH1_IP"
EOF

sudo systemctl daemon-reload
sudo systemctl restart jenkins

# verify that Jenkins is listening on the correct IP and port
# sudo ss -lntp | grep ':8080'
# expected smth like this:
# LISTEN ... 192.168.56.23:8080 ...


echo "=== Jenkins bootstrap completed ==="
date

echo "Installation log available at $LOG_FILE"

ls -l /var/lib/jenkins
echo "To move Jenkins, stop the service, archive /var/lib/jenkins, and restore it elsewhere"