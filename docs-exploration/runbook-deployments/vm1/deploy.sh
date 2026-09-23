#!/bin/bash
set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source params.env
source "${SCRIPT_DIR}/params.env"

echo "===================================================="
echo "Deploying AgentENV VM Instance"
echo "Project:       ${PROJECT_ID}"
echo "Zone:          ${ZONE}"
echo "VM Name:       ${VM_NAME}"
echo "Machine Type:  ${MACHINE_TYPE}"
echo "Image Family:  ${IMAGE_FAMILY}"
echo "===================================================="

# Set GCP config
echo "Configuring gcloud project and zone..."
gcloud config set project "${PROJECT_ID}"
gcloud config set compute/zone "${ZONE}"

# Create GCE VM with nested virtualization enabled
echo "Creating GCE VM instance ${VM_NAME}..."
gcloud compute instances create "${VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --enable-nested-virtualization \
    --labels="repo-agent-instance=${RESOURCE_PREFIX}" \
    --metadata=startup-script="#!/bin/bash
# Ensure compilation-essential and runtime dependencies are ready
apt-get update
apt-get install -y git build-essential pkg-config libssl-dev protobuf-compiler clang libclang-dev libprotobuf-dev ca-certificates curl e2fsprogs iproute2 iptables jq sudo umoci zstd setpriv
"

# Wait for SSH to be ready
echo "Waiting for VM to be accessible via SSH..."
for i in {1..30}; do
    if gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --command="echo 'SSH is ready'" --quiet >/dev/null 2>&1; then
        echo "Successfully connected to VM!"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "Failed to connect to VM after 300 seconds."
        exit 1
    fi
    sleep 10
done

# Wait for startup script to finish
echo "Waiting for startup script to finish installing dependencies..."
gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --command="
    while systemctl is-active google-startup-scripts.service >/dev/null 2>&1; do
        echo 'Startup-script is still running, waiting 10 seconds...'
        sleep 10
    done
    echo 'Startup-script has completed successfully!'
"

# Create helper vm_setup.sh script to execute inside the VM
echo "Creating helper setup script..."
cat << 'EOF' > "${SCRIPT_DIR}/vm_setup.sh"
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
EOF

# Copy setup script to VM
echo "Copying setup script to VM..."
gcloud compute scp "${SCRIPT_DIR}/vm_setup.sh" "${VM_NAME}:~/vm_setup.sh" --zone="${ZONE}"

# Run setup script on VM
echo "Executing setup script on VM..."
gcloud compute ssh "${VM_NAME}" --zone="${ZONE}" --command="bash ~/vm_setup.sh"

# Clean up local helper script copy
rm -f "${SCRIPT_DIR}/vm_setup.sh"

echo "===================================================="
echo "Deployment and verification completed successfully!"
echo "===================================================="
