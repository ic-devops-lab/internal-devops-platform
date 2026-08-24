# OmniRoute Service Guide

## About OmniRoute

OmniRoute is a free, MIT-licensed, open-source AI gateway designed to pool multiple Large Language Model (LLM) providers into a single, unified, OpenAI-compatible endpoint (`localhost:20128`).

By acting as a local proxy between developer applications and AI APIs, OmniRoute allows developers to use popular AI coding tools and agents—such as Claude Code, Cursor, Cline, Aider, and GitHub Copilot—without hitting usage or subscription limits.

**Key Features**
- ***Massive Provider Integration***: Centralizes access to over ***290 AI providers*** and ***516 individual models*** (including GPT, Claude, Gemini, DeepSeek, and Mistral).
- ***1.6 Billion Free Tokens***: Aggregates the free usage tiers of 90+ integrated providers (40+ of which are "free forever" with no credit card required), making high-volume AI coding nearly cost-free.- - ***Resilient Auto-Fallback***: Uses a 3-layer self-healing mechanism (circuit breakers, cooldowns, and model lockouts) across 19 different routing strategies. If one provider gets rate-limited, OmniRoute instantly switches to the next available provider seamlessly.
- ***Deep Token Compression***: Employs a 12-engine compression stack (RTK + Caveman) that compresses prompts to save between ***15% to 95% on token usage***.
- ***Local-First Infrastructure***: Runs locally on your machine via npm or Docker. Your requests bypass external analytics platforms and flow only through your container directly to the providers.

---

## Manual setup

```bash
# Update Debian and Install Dependencies
sudo apt update && sudo apt upgrade -y
sudo apt install -y ca-certificates curl gnupg lsb-release

# uninstall all conflicting packages
sudo apt remove $(dpkg --get-selections docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc | cut -f1)

# Add Docker's official GPG key:
sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update

# Install the Docker packages
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# verify docker
sudo systemctl status --no-pager docker
sudo docker run hello-world

# add current user to docker group
sudo groupadd docker > /dev/null
sudo usermod -aG docker $USER
newgrp docker

# Create the OmniRoute Application Directory
mkdir -p ~/omniroute/data && cd $_

tee .env <<EOF
OMNIROUTE_INITIAL_PASSWORD=YourSecureAdminPasswordHere
EOF

tee compose.yaml <<EOF
services:
  omniroute:
    image: diegosouzapw/omniroute:latest
    container_name: omniroute
    restart: unless-stopped
    ports:
      - "20128:20128"
    environment:
      - NODE_ENV=production
      - HOSTNAME=0.0.0.0
      - INITIAL_PASSWORD=${OMNIROUTE_INITIAL_PASSWORD}
      - REQUIRE_API_KEY=true
    volumes:
      - ./data:/root/.omniroute
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

# start omniroute container
docker compose up -d
```

On the host:
```bash
dig @192.168.56.2 omniroute.lab.internal
```
Try on local machine under OpenVPN in the browser: http://omniroute.lab.internal
endpoint: http://omniroute.lab.internal/api/v1

---
