#!/usr/bin/env bash
# Deploy AgentENV onto GCP GCE VM via manual compilation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/params.env"

echo "=== Step 1: Create Firewall Rule for AgentENV HTTP API ==="
if ! gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME}" --project="${PROJECT}" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "${FIREWALL_RULE_NAME}" \
    --project="${PROJECT}" \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:8000 \
    --target-tags=agentenv-node \
    --description="Allow AgentENV HTTP API traffic on port 8000"
else
  echo "Firewall rule ${FIREWALL_RULE_NAME} already exists."
fi

echo "=== Step 2: Provision GCE VM with Nested Virtualization ==="
if ! gcloud compute instances describe "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" >/dev/null 2>&1; then
  gcloud compute instances create "${INSTANCE_NAME}" \
    --project="${PROJECT}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --boot-disk-size="${BOOT_DISK_SIZE_GB}GB" \
    --boot-disk-type=pd-balanced \
    --enable-nested-virtualization \
    --tags=agentenv-node \
    --labels="repo-agent-instance=${RESOURCE_PREFIX}" \
    --metadata=startup-script='#!/usr/bin/env bash
set -euxo pipefail

# Wait for cloud-init and apt locks
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done

# Install required build tools and runtime dependencies
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    pkg-config \
    libssl-dev \
    protobuf-compiler \
    clang \
    libclang-dev \
    git \
    curl \
    jq \
    make \
    iproute2 \
    iptables \
    socat \
    zstd \
    ca-certificates

# Load and persist ublk_drv kernel module
modprobe ublk_drv ublks_max=4096 || true
echo ublk_drv > /etc/modules-load.d/aenv-ublk.conf

# Tune host kernel parameters
cat <<EOF > /etc/sysctl.d/99-aenv.conf
net.ipv4.ip_forward = 1
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384
net.netfilter.nf_conntrack_max = 1048576
kernel.pid_max = 4194304
fs.inotify.max_user_instances = 8192
EOF
sysctl --system || true
'
else
  echo "Instance ${INSTANCE_NAME} already exists."
fi

echo "=== Step 3: Wait for Instance SSH and Readiness ==="
echo "Waiting for instance ${INSTANCE_NAME} to become reachable..."
until gcloud compute ssh "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --command="echo instance is ready" --quiet; do
  echo "Retrying SSH connection in 5 seconds..."
  sleep 5
done

echo "=== Step 4: Build AgentENV from Source on the VM ==="
gcloud compute ssh "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --command='bash -s' <<'EOF'
set -euxo pipefail

# Install Rust stable toolchain
if ! command -v cargo &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
else
    source "$HOME/.cargo/env" || true
fi

# Clone repository
if [[ ! -d "AgentENV" ]]; then
    git clone https://github.com/kvcache-ai/AgentENV.git
fi
cd AgentENV

# Build release artifacts
make release
make install-aenv
make install-ublk PROFILE=release

# Verify binaries
/usr/local/bin/aenv --version
EOF

echo "=== Step 5: Configure Host and Provision Runtime Assets ==="
gcloud compute ssh "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --command='bash -s' <<'EOF'
set -euxo pipefail
cd AgentENV

# Configure host environment permissions, ublk, and forwarding
sudo ./target/release/server --setup-host

# Provision Firecracker binary, guest kernel, and rootfs dependencies
sudo ./target/release/server --setup-only
EOF

echo "=== Step 6: Start AgentENV Systemd Service ==="
gcloud compute ssh "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --command='bash -s' <<'EOF'
set -euxo pipefail

sudo tee /etc/systemd/system/aenv.service > /dev/null <<'UNIT'
[Unit]
Description=AgentENV Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/AgentENV
Environment="AENV_HOME_PATH=/var/lib/aenv"
Environment="API_ADDR=0.0.0.0:8000"
ExecStart=/root/AgentENV/target/release/server
Restart=always
RestartSec=3
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
UNIT

# Enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable --now aenv.service
sudo systemctl status aenv.service --no-pager
EOF

echo "=== Step 7: Verify Server Health and Endpoints ==="
gcloud compute ssh "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --command='bash -s' <<'EOF'
set -euo pipefail
sleep 3
echo "Checking /health endpoint:"
curl -fsSL http://127.0.0.1:8000/health
echo ""

API_KEY="$(sudo cat /var/lib/aenv/secrets/api-key)"
echo "Retrieved API key."

echo "Checking /sandboxes endpoint:"
curl -fsSL -H "X-API-Key: ${API_KEY}" http://127.0.0.1:8000/sandboxes
echo ""
EOF

VM_EXTERNAL_IP="$(gcloud compute instances describe "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
echo "Testing external connectivity to http://${VM_EXTERNAL_IP}:8000/health..."
curl -fsSL "http://${VM_EXTERNAL_IP}:8000/health"
echo "AgentENV server deployment complete and healthy at http://${VM_EXTERNAL_IP}:8000"
