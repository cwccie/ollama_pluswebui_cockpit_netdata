#!/bin/bash

set -e  # Exit on error
set -o pipefail  # Catch pipeline errors
set -u  # Treat unset variables as errors

echo "Starting system setup..."

# Check disk and extend logical volume
lsblk
sudo vgdisplay ubuntu-vg
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
df -h

# Update and upgrade system
sudo apt update && sudo apt upgrade -y

# Install Cockpit
sudo apt install -y cockpit
sudo systemctl enable --now cockpit.socket

# Install Netdata
sudo apt install -y netdata
sudo systemctl enable --now netdata

# Configure Netdata to allow external access
sudo sed -i 's/bind socket to IP = 127.0.0.1/bind socket to IP = 0.0.0.0/' /etc/netdata/netdata.conf
sudo systemctl restart netdata

# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Install dependencies for Docker
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Setup Docker GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index again
sudo apt-get update

# Install Docker
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Verify Docker installation
sudo docker --version

# Run test container
sudo docker run hello-world

# Add user to Docker group (only needs to be done once)
sudo usermod -aG docker $USER
newgrp docker

# Deploy Open WebUI container
docker run -d -p 3000:8080 --add-host=host.docker.internal:host-gateway -v open-webui:/app/backend/data --name open-webui --restart always ghcr.io/open-webui/open-webui:main

# Open WebUI webpage address
echo "Open WebUI is available at: http://localhost:3000"

# Check Docker bridge network
docker network inspect bridge

# Replace Ollama systemd service file
sudo tee /etc/systemd/system/ollama.service > /dev/null <<EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"
Environment="OLLAMA_HOST=172.17.0.1"

[Install]
WantedBy=default.target
EOF

# Reload and restart Ollama service
sudo systemctl daemon-reload
sudo systemctl restart ollama

# Pull additional models
ollama pull phi4:14b
ollama pull llama3.2:3b
ollama pull deepseek-r1:14b
ollama pull mistral:7b
ollama pull mixtral:8x7b

# Restart all services in order
echo "Restarting services..."
sudo systemctl restart ollama
sudo systemctl restart docker
sudo systemctl restart cockpit.socket
sudo systemctl restart netdata

# Echo service addresses
echo "Setup Complete!"
echo "Netdata is available at: http://<ip>:19999"
echo "Ollama-WebUI is available at: http://<ip>:3000"
echo "Cockpit is available at: http://<ip>:9090"

exit 0
