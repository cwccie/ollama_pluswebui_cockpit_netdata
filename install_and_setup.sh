#!/bin/bash

set -e                   # Exit immediately if a command exits with a non-zero status
set -o pipefail          # Ensure that errors in a pipeline are not masked
set -u                   # Treat unset variables as an error and exit immediately

echo "Starting system setup..."

# Determine the real (non-root) user if running via sudo
if [ -n "${SUDO_USER:-}" ]; then
    REAL_USER="$SUDO_USER"
else
    REAL_USER="$USER"
fi

# Capture the server's IP address (first IP from hostname -I)
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Detected Server IP: $SERVER_IP"

# Set Flask port
FLASK_PORT=5050

# Extend logical volume (if additional free space is available)
echo "Checking available disk space..."
sudo lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv && sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
echo "Disk extended successfully!"
df -h

# Configure Docker GPG key for APT
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Update and upgrade system packages
sudo apt update && sudo apt upgrade -y

# Install Python, Pip, and Virtual Environment support
echo "Installing Python, Pip, and Virtual Environment support..."
sudo apt install -y python3 python3-pip python3-venv

# Install Cockpit
sudo apt install -y cockpit
sudo systemctl enable --now cockpit.socket

# Install Netdata and configure it for external access
sudo apt install -y netdata
sudo systemctl enable --now netdata
sudo sed -i 's/bind socket to IP = 127.0.0.1/bind socket to IP = 0.0.0.0/' /etc/netdata/netdata.conf
sudo systemctl restart netdata

# Install Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Install additional dependencies for Docker
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker repository and update package lists
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# Install Docker components
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo docker --version

# Run test Docker container
sudo docker run hello-world

# Add the real user to the docker group (requires log out/in for changes to take effect)
sudo usermod -aG docker "$REAL_USER"

# Remove any existing container named "open-webui"
docker rm -f open-webui || true

# Deploy the Open WebUI container
docker run -d -p 3000:8080 --add-host=host.docker.internal:host-gateway -v open-webui:/app/backend/data --name open-webui --restart always ghcr.io/open-webui/open-webui:main
echo "Open WebUI is available at: http://$SERVER_IP:3000"

# Inspect the Docker bridge network (for debugging)
docker network inspect bridge

# Create or replace the systemd service for Ollama
sudo tee /etc/systemd/system/ollama.service > /dev/null <<'EOF'
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

# Reload systemd and restart Ollama service
sudo systemctl daemon-reload
sudo systemctl restart ollama

# Wait for Ollama API to become available
echo "Waiting for Ollama to become available..."
OLLAMA_AVAILABLE=false
for i in {1..20}; do
    if curl -fsSL http://127.0.0.1:11434 >/dev/null 2>&1; then
        echo "Ollama is available."
        OLLAMA_AVAILABLE=true
        break
    else
        echo "Ollama not available yet, waiting... ($i/20)"
        sleep 5
    fi
done

# Pull Ollama models if the API is available; otherwise, warn and skip model pulls.
if [ "$OLLAMA_AVAILABLE" = true ]; then
    echo "Pulling Ollama models..."
    ollama pull phi4:14b || echo "Failed to pull phi4:14b"
    ollama pull llama3.2:3b || echo "Failed to pull llama3.2:3b"
    ollama pull deepseek-r1:14b || echo "Failed to pull deepseek-r1:14b"
    ollama pull mistral:7b || echo "Failed to pull mistral:7b"
    ollama pull mixtral:8x7b || echo "Failed to pull mixtral:8x7b"
    ollama pull deepseek-r1:32b || echo "Failed to pull deepseek-r1:32b"
    ollama pull codellama:7b || echo "Failed to pull codellama:7b"
    ollama pull deepseek-coder-v2:16b || echo "Failed to pull deepseek-coder-v2:16b"
    ollama pull codellama:13b || echo "Failed to pull codellama:13b"
    ollama pull codellama:34b || echo "Failed to pull codellama:34b"
    ollama pull deepseek-r1:70b || echo "Failed to pull deepseek-r1:70b"
    ollama pull llama3.3:70b || echo "Failed to pull llama3.3:70b"
else
    echo "Warning: Ollama API did not become available after waiting. Skipping model pulls."
fi

# Setup Python Virtual Environment for Flask application
echo "Setting up Python Virtual Environment..."
FLASK_APP_DIR="/opt/flask_app"
FLASK_VENV="$FLASK_APP_DIR/venv"

sudo mkdir -p "$FLASK_APP_DIR"
sudo chown -R "$REAL_USER":"$REAL_USER" "$FLASK_APP_DIR"

# Create the virtual environment
python3 -m venv "$FLASK_VENV"

# Activate the virtual environment and install Python dependencies
source "$FLASK_VENV/bin/activate"
pip install --upgrade pip
pip install flask numpy pandas tqdm tabulate seaborn matplotlib prettytable torch networkx \
    deap umap-learn scikit-learn imbalanced-learn ucimlrepo
deactivate

# Create the Flask application file
echo "Creating Flask Application..."
sudo tee "$FLASK_APP_DIR/app.py" > /dev/null <<EOF
from flask import Flask

app = Flask(__name__)

@app.route('/')
def home():
    return "<h1>Welcome to the Flask Landing Page!</h1>"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=${FLASK_PORT}, debug=False)
EOF

# Create systemd service for the Flask application
echo "Creating Flask systemd service..."
sudo tee /etc/systemd/system/flask.service > /dev/null <<EOF
[Unit]
Description=Flask Web Application
After=network.target

[Service]
User=${REAL_USER}
WorkingDirectory=${FLASK_APP_DIR}
ExecStart=${FLASK_VENV}/bin/python ${FLASK_APP_DIR}/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Set appropriate permissions and enable the Flask service
sudo chmod -R 755 "$FLASK_APP_DIR"
sudo systemctl daemon-reload
sudo systemctl enable flask
sudo systemctl restart flask

# Install and configure Samba for SMB shares
echo "Installing Samba..."
sudo apt install -y samba
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

echo "Configuring SMB share for your home directory..."
sudo tee -a /etc/samba/smb.conf > /dev/null <<EOF

[UserShare]
   comment = User Folder Share
   path = /home/${REAL_USER}
   browsable = yes
   guest ok = yes
   read only = no
   force user = ${REAL_USER}
EOF

sudo systemctl restart smbd

# Final echo statements with proper SERVER_IP substitution
echo "Setup Complete!"
echo "Netdata is available at: http://$SERVER_IP:19999"
echo "Ollama-WebUI is available at: http://$SERVER_IP:3000"
echo "Cockpit is available at: http://$SERVER_IP:9090"
echo "Flask Web Application is available at: http://$SERVER_IP:${FLASK_PORT}"
echo "SMB share available at: smb://$SERVER_IP/UserShare (accessible without credentials)"

exit 0
