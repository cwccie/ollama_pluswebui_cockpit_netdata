sudo apt update && sudo apt install -y git

sudo tee /etc/systemd/system/setup.service > /dev/null <<EOF
[Unit]
Description=Automatic Setup on Boot
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c "curl -fsSL https://raw.githubusercontent.com/cwccie/ollama_pluswebui_cockpit_netdata/main/install_and_setup.sh | sudo bash"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
sudo systemctl daemon-reload
sudo systemctl enable setup.service
