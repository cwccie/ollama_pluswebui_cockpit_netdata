#!/bin/bash
# Ultimate install_and_setup.sh
# This script installs and configures Cockpit, Netdata, Ollama, Docker,
# a Flask landing page, and required Python packages.
# It creates systemd services for Ollama and Flask, then restarts all services.
# All Ollama models from previous versions are included.

set -e  # Exit on error
set -o pipefail  # Catch pipeline errors
set -u  # Treat unset variables as errors

# Banner function for clear section separation
banner() {
    echo "======================================="
    echo "$1"
    echo "======================================="
}

banner "STARTING SYSTEM SETUP"

# Detect server IP and set Flask port
SERVER_IP=$(hostname -I | awk '{print $1}')
export SERVER_IP
echo "Detected Server IP: $SERVER_IP"
FLASK_PORT=5050
export FLASK_PORT
echo "Flask will run on port: $FLASK_PORT"

banner "EXTENDING DISK VOLUME"
echo "Checking available disk space and extending logical volume..."
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv && sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
echo "Disk extended successfully!"
df -h

banner "FIXING DOCKER GPG KEY ISSUE"
echo "Setting up Docker GPG key..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

banner "SYSTEM UPDATE AND UPGRADE"
sudo apt update && sudo apt upgrade -y

banner "INSTALLING PYTHON, PIP, AND FLASK"
echo "Installing Python3 and pip..."
sudo apt install -y python3 python3-pip
echo "Installing Flask..."
pip3 install --break-system-packages --ignore-installed flask

banner "INSTALLING COCKPIT"
sudo apt install -y cockpit
sudo systemctl enable --now cockpit.socket

banner "INSTALLING NETDATA"
sudo apt install -y netdata
sudo systemctl enable --now netdata
echo "Configuring Netdata for external access..."
sudo sed -i 's/bind socket to IP = 127.0.0.1/bind socket to IP = 0.0.0.0/' /etc/netdata/netdata.conf
sudo systemctl restart netdata

banner "INSTALLING OLLAMA"
echo "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

banner "INSTALLING DOCKER DEPENDENCIES AND DOCKER"
echo "Installing Docker dependencies..."
sudo apt-get install -y ca-certificates curl gnupg lsb-release
echo "Adding Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
echo "Installing Docker..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo docker --version
echo "Running Docker test container..."
sudo docker run hello-world

echo "Adding current user ($USER) to Docker group..."
sudo usermod -aG docker $USER
newgrp docker

banner "DEPLOYING OPEN WEBUI CONTAINER"
echo "Removing any existing Open WebUI container..."
docker rm -f open-webui || true
echo "Deploying Open WebUI container..."
docker run -d -p 3000:8080 --add-host=host.docker.internal:172.17.0.1 \
  -v open-webui:/app/backend/data --name open-webui --restart always \
  ghcr.io/open-webui/open-webui:main
echo "Open WebUI should be available at: http://$SERVER_IP:3000"
docker network inspect bridge

banner "CONFIGURING OLLAMA SYSTEMD SERVICE"
echo "Creating custom Ollama systemd service file with OLLAMA_HOST set to 0.0.0.0..."
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
Environment="OLLAMA_HOST=0.0.0.0"

[Install]
WantedBy=default.target
EOF

echo "Reloading systemd and restarting Ollama service..."
sudo systemctl daemon-reload
sudo systemctl restart ollama

banner "PULLING OLLAMA MODELS"
echo "Pulling additional Ollama models..."
ollama pull tinyllama:1.1b
ollama pull llama3.2:3b
ollama pull mistral:7b
ollama pull codellama:7b
ollama pull wizard-vicuna-uncensored:7b
ollama pull wizard-vicuna-uncensored:13b
ollama pull codellama:13b
ollama pull phi4:14b
ollama pull deepseek-r1:14b
ollama pull deepseek-coder-v2:16b
ollama pull wizard-vicuna-uncensored:30b
ollama pull Godmoded/llama3-lexi-uncensored
ollama pull deepseek-r1:32b
ollama pull codellama:34b
ollama pull deepseek-r1:70b
ollama pull llama3.3:70b
ollama pull mixtral:8x7b
ollama pull dolphin-mixtral:8x7b
ollama pull dolphin-mixtral:8x22b

banner "INSTALLING ADDITIONAL PYTHON PACKAGES"
echo "Upgrading pip and installing required Python packages..."
pip3 install --upgrade pip --break-system-packages --ignore-installed
pip3 install --break-system-packages --ignore-installed \
    numpy pandas tqdm tabulate seaborn matplotlib prettytable torch networkx \
    deap umap-learn scikit-learn imbalanced-learn ucimlrepo flask

banner "SETTING UP FLASK WEB APPLICATION"
FLASK_APP_DIR="/opt/flask_app"
echo "Creating Flask application directory at $FLASK_APP_DIR..."
sudo mkdir -p "$FLASK_APP_DIR"
echo "Creating Flask app..."
sudo tee "$FLASK_APP_DIR/app.py" > /dev/null <<EOF
from flask import Flask

app = Flask(__name__)

@app.route('/')
def home():
    return "<h1>Welcome to the Flask Landing Page!</h1>"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=$FLASK_PORT, debug=False)
EOF

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

echo "Setting permissions for Flask application..."
sudo chmod -R 755 "$FLASK_APP_DIR"
sudo systemctl daemon-reload
sudo systemctl enable flask
sudo systemctl restart flask

banner "FINAL SERVICE RESTARTS AND SUMMARY"
echo "Restarting all services..."
sudo systemctl restart ollama
sudo systemctl restart docker
sudo systemctl restart cockpit.socket
sudo systemctl restart netdata
sudo systemctl restart flask

echo "======================================="
echo "SETUP COMPLETE!"
echo "Netdata is available at: http://$SERVER_IP:19999"
echo "Ollama-WebUI is available at: http://$SERVER_IP:3000"
echo "Cockpit is available at: http://$SERVER_IP:9090"
echo "Flask Web Application is available at: http://$SERVER_IP:$FLASK_PORT"
echo "======================================="

exit 0
