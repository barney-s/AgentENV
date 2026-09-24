#!/bin/bash
set -euo pipefail

echo "===================================================="
echo "Inside VM: Setting up Host Virtualization & Rust"
echo "===================================================="

# Configure overlaybd default configuration path
sudo mkdir -p /etc/overlaybd
sudo sh -c "echo '{}' > /etc/overlaybd/overlaybd.json"

# Clone repository
if [ ! -d "AgentENV" ]; then
    echo "Cloning AgentENV repo..."
    git clone https://github.com/kvcache-ai/AgentENV.git
fi
cd AgentENV

# Run host-setup script to load ublk_drv and apply sysctl tunings
echo "Running docker-setup.sh for kernel tuning..."
sudo bash scripts/docker-setup.sh

# Verify KVM access
echo "Verifying /dev/kvm access..."
ls -l /dev/kvm

# Install Rust toolchain
echo "Installing Rust toolchain..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"

# Compile AgentENV from source
echo "Compiling AgentENV in release mode (this may take a few minutes)..."
make release

# Install the custom CLI (aenv) globally
echo "Installing aenv globally..."
sudo make install-aenv

# Start the AgentENV Server bare-metal in the background
echo "Starting AgentENV Server on port 8000..."
nohup make start-server-release API_ADDR=0.0.0.0:8000 > "$HOME/agentenv.log" 2>&1 &
sleep 5

# Verification
echo "===================================================="
echo "Inside VM: Verifying server deployment"
echo "===================================================="

echo "=== 1. Checking health endpoint ==="
curl -fsS http://127.0.0.1:8000/health

echo "=== 2. Extracting API key ==="
export AENV_API_KEY=$(sudo cat /var/lib/aenv/secrets/api-key)
echo "Extracted API Key: ${AENV_API_KEY}"

echo "=== 3. Querying sandboxes list ==="
curl -fsS -H "X-API-Key: ${AENV_API_KEY}" http://127.0.0.1:8000/sandboxes

echo "Setup completed successfully inside VM!"
