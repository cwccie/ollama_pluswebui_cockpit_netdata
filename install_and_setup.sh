#!/bin/bash
# install_and_setup.sh
# This script installs and configures Cockpit, Netdata, Ollama, Docker,
# and a Flask landing page with required Python packages.
# It also creates systemd services for Ollama and Flask, then restarts all services.

set -e  # Exit on error
set -o pipefail  # Catch pipeline errors
set -u  # Treat unset variables as errors

echo "Starting system setup..."

# Detect server IP
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Detected Server IP: $SERVER_IP"

# Set Flask Port (choose a port not in use: 80, 3000, 9090, 19999)
FLASK_PORT=5050

# Extend logical volume (only if there is free space available)
echo "Checking available disk space..."
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv && sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
echo "Disk extended successfully!"
df -h

# Fix Docker GPG Key Issue
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Update and upgrade system
sudo apt update && sudo apt upgrade -y

# Install Python, pip, and Flask
echo "Installing Python and Pip..."
sudo apt install -y python3 python3-pip
echo "Installing Flask..."
pip3 install --break-system-packages --ignore-installed flask

# Install Cockpit
echo "Installing Cockpit..."
sudo apt install -y cockpit
sudo systemctl enable --now cockpit.socket

# Install Netdata
echo "Installing Netdata..."
sudo apt install -y netdata
sudo systemctl enable --now netdata
echo "Configuring Netdata to allow external access..."
sudo sed -i 's/bind socket to IP = 127.0.0.1/bind socket to IP = 0.0.0.0/' /etc/netdata/netdata.conf
sudo systemctl restart netdata

# Install Ollama
echo "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# Install dependencies for Docker
echo "Installing Docker dependencies..."
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker repository
echo "Adding Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index again
sudo apt-get update

# Install Docker
echo "Installing Docker..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo docker --version

# Run test container
echo "Running Docker test container..."
sudo docker run hello-world

# Add current user to Docker group
echo "Adding current user to Docker group..."
sudo usermod -aG docker $USER
newgrp docker

# Fix Open WebUI Conflict - Remove existing container if present
echo "Removing any existing Open WebUI container..."
docker rm -f open-webui || true

# Deploy Open WebUI container
echo "Deploying Open WebUI container..."
docker run -d -p 3000:8080 --add-host=host.docker.internal:172.17.0.1 \
  -e OLLAMA_HOST=host.docker.internal:11434 \
  -v open-webui:/app/backend/data --name open-webui --restart always \
  ghcr.io/open-webui/open-webui:main
echo "Open WebUI is available at: http://$SERVER_IP:3000"

# Check Docker bridge network
docker network inspect bridge

# Replace Ollama systemd service file
echo "Configuring Ollama systemd service..."
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

# Pull additional Ollama models
echo "Pulling additional Ollama models..."
ollama pull phi4:14b
ollama pull llama3.2:3b
ollama pull deepseek-r1:14b
ollama pull mistral:7b
ollama pull mixtral:8x7b

# Install additional Python packages
echo "Installing required Python packages..."
pip3 install --upgrade pip --break-system-packages --ignore-installed
pip3 install --break-system-packages --ignore-installed \
    numpy pandas tqdm tabulate seaborn matplotlib prettytable torch networkx \
    deap umap-learn scikit-learn imbalanced-learn ucimlrepo flask

# Set up Flask application
echo "Setting up Flask Web Application..."
FLASK_APP_DIR="/opt/flask_app"
sudo mkdir -p "$FLASK_APP_DIR"
sudo tee "$FLASK_APP_DIR/app.py" > /dev/null <<EOF
from flask import Flask

app = Flask(__name__)

@app.route('/')
def home():
    return "<h1>Welcome to the Flask Landing Page!</h1>"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=$FLASK_PORT, debug=False)
EOF

# Create systemd service for Flask
echo "Creating systemd service for Flask..."
sudo tee /etc/systemd/system/flask.service > /dev/null <<EOF
[Unit]
Description=Flask Web Application
After=network.target

[Service]
User=root
WorkingDirectory=$FLASK_APP_DIR
ExecStart=/usr/bin/python3 $FLASK_APP_DIR/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Set permissions and enable Flask service
sudo chmod -R 755 "$FLASK_APP_DIR"
sudo systemctl daemon-reload
sudo systemctl enable flask
sudo systemctl restart flask

# Restart all services in order
echo "Restarting services..."
sudo systemctl restart ollama
sudo systemctl restart docker
sudo systemctl restart cockpit.socket
sudo systemctl restart netdata
sudo systemctl restart flask

# Echo final service addresses
echo "======================================="
echo "Setup Complete!"
echo "Netdata is available at: http://$SERVER_IP:19999"
echo "Ollama-WebUI is available at: http://$SERVER_IP:3000"
echo "Cockpit is available at: http://$SERVER_IP:9090"
echo "Flask Web Application is available at: http://$SERVER_IP:$FLASK_PORT"
echo "======================================="

exit 0
