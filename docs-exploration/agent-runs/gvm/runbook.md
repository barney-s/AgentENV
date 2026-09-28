# AgentENV GCE Deployment Runbook (gvm)

This runbook defines the procedure to deploy AgentENV onto Google Cloud Platform (GCE) by building it directly from source according to the [AgentENV Manual Compile Guide](https://kvcache-ai.github.io/AgentENV/latest/deployment/manual-compile.html).

## What this needs

Can this run in a container pod, or does it need real infrastructure?
**It requires real infrastructure (a dedicated Compute Engine VM).**

AgentENV requires:
1. Direct access to `/dev/kvm` for Firecracker microVM hardware virtualization. On GCP, this requires a Compute Engine VM with **nested virtualization enabled** (`--enable-nested-virtualization`).
2. The `ublk_drv` Linux kernel module (with kernel 6.8+) for userspace block device support used by OverlayBD / UVM storage.
3. Elevated host privileges (`CAP_NET_ADMIN`, `CAP_SYS_ADMIN`, host network namespaces, network forwarding `/proc/sys/net/ipv4/ip_forward`).

### Pre-run Feasibility Checklist

- [x] GCP Project Access: `barni-cnrm-20260529`
- [x] GCP Compute Region / Zone: `us-central1` / `us-central1-a`
- [x] Compute Instance Create permission (`compute.instances.create`)
- [x] Compute Firewall Rules permission (`compute.firewalls.create`)
- [x] Nested Virtualization on GCE (`n2-standard-4` on Intel Cascade Lake / Ice Lake supports nested virtualization)
- [x] OS Image: Ubuntu 24.04 LTS (`ubuntu-2404-lts-amd64`) with Linux kernel 6.8+
- [x] Local CLI tools: `gcloud`, `git`, `curl`, `jq` present in planning environment

## Preconditions

Ensure you are authenticated to Google Cloud and have configured the target project and zone:

```bash
gcloud config set project "${PROJECT}"
gcloud config set compute/region "${REGION}"
gcloud config set compute/zone "${ZONE}"
```

Source the run configuration:

```bash
source docs-exploration/agent-runs/gvm/params.env
```

## Steps

### Step 1: Create Firewall Rule for AgentENV HTTP API

AgentENV listens on port 8000 for client API requests. We create a firewall rule allowing TCP ingress on port 8000 for instances tagged with `agentenv-node`.

```bash
gcloud compute firewall-rules create "${FIREWALL_RULE_NAME}" \
  --project="${PROJECT}" \
  --direction=INGRESS \
  --priority=1000 \
  --network=default \
  --action=ALLOW \
  --rules=tcp:8000 \
  --target-tags=agentenv-node \
  --description="Allow AgentENV HTTP API traffic on port 8000"
```

### Step 2: Provision GCE VM with Nested Virtualization

Create an `n2-standard-4` Compute Engine instance running Ubuntu 24.04 LTS (kernel 6.8+) with nested virtualization enabled (`--enable-nested-virtualization`). Nested virtualization is mandatory for Firecracker microVMs to execute with KVM acceleration. The startup script installs build/runtime packages (including `libprotobuf-dev` for standard protobuf headers), creates the system `aenv` account, loads the `ublk_drv` module, and configures kernel networking parameters.

```bash
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
    libprotobuf-dev \
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

# Create runtime system group and user
if ! getent group aenv >/dev/null 2>&1; then
    groupadd --system aenv
fi
if ! id -u aenv >/dev/null 2>&1; then
    useradd --system --gid aenv --home-dir /var/lib/aenv --no-create-home --shell /usr/sbin/nologin aenv
fi

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
```

### Step 3: Wait for Instance SSH and Readiness

Wait for the instance to complete startup, become accessible via Google Cloud SSH, and ensure background startup script package installation has finished before starting build tasks:

```bash
echo "Waiting for instance ${INSTANCE_NAME} to become reachable..."
until gcloud compute ssh "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --command="echo instance is ready" --quiet; do
  echo "Retrying SSH connection in 5 seconds..."
  sleep 5
done

echo "Waiting for background startup script and package installation to complete..."
gcloud compute ssh "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --command='bash -s' <<'EOF'
set -euo pipefail
while systemctl is-active --quiet google-startup-scripts.service; do
    echo "Startup script is still running..."
    sleep 3
done
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo "Waiting for apt/dpkg lock..."
    sleep 3
done
EOF
```

### Step 4: Build AgentENV from Source on the VM

SSH into the instance, install the Rust toolchain, clone the repository, set `PROTOC_INCLUDE=/usr/include` for `prost-build`, compile the release binaries (`server`, `aenv`, `uvm-ublk-daemon`), and install them to standard system locations:

```bash
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

# Build release artifacts with standard protobuf include path
export PROTOC_INCLUDE=/usr/include
cargo build --release -p agentenv --bin server -p aenv --bin aenv -p uvm-ublk-daemon --bin uvm-ublk-daemon

# Install compiled binaries to standard system locations
sudo install -d /usr/local/bin
sudo install -m 0755 target/release/aenv /usr/local/bin/aenv
sudo install -m 0755 target/release/server /usr/local/bin/server
sudo install -d /var/lib/aenv/ublk
sudo install -m 0755 target/release/uvm-ublk-daemon /var/lib/aenv/ublk/uvm-ublk-daemon

# Verify binary availability
/usr/local/bin/aenv --version
/usr/local/bin/server --help
EOF
```

### Step 5: Configure Host and Provision Runtime Assets

Prepare `/var/lib/aenv/config/config.toml`, download Firecracker / OverlayBD / guest kernel assets with `--setup-only`, provision ublk access rules and system overlaybd config with `--setup-host`, and resolve the base tools image:

```bash
gcloud compute ssh "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --command='bash -s' <<'EOF'
set -euxo pipefail
cd AgentENV

# Ensure runtime user and group exist
if ! getent group aenv >/dev/null 2>&1; then
    sudo groupadd --system aenv
fi
if ! id -u aenv >/dev/null 2>&1; then
    useradd --system --gid aenv --home-dir /var/lib/aenv --no-create-home --shell /usr/sbin/nologin aenv
fi

# Prepare /var/lib/aenv directory and configuration
sudo install -d -o aenv -g aenv -m 0750 /var/lib/aenv
sudo install -d -o aenv -g aenv -m 0750 /var/lib/aenv/config
sudo install -o aenv -g aenv -m 0640 config/default.toml /var/lib/aenv/config/config.toml

# Provision runtime assets (downloads dependencies first)
sudo /usr/local/bin/server --setup-only --config /var/lib/aenv/config/config.toml || true

# Configure host environment permissions, ublk, and overlaybd system config
sudo /usr/local/bin/server --setup-host --runtime-user aenv --runtime-group aenv --config /var/lib/aenv/config/config.toml

# Finalize image resolution and tools provisioning
sudo /usr/local/bin/server --setup-only --config /var/lib/aenv/config/config.toml

# Ensure runtime state directory permissions
sudo chown -R aenv:aenv /var/lib/aenv
EOF
```

### Step 6: Start AgentENV Systemd Service

Create and start the `aenv` systemd service running as non-root user `aenv` with required network and system capabilities (`CAP_NET_ADMIN`, `CAP_SYS_ADMIN`) and access to the `kvm` group:

```bash
gcloud compute ssh "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --command='bash -s' <<'EOF'
set -euxo pipefail

sudo tee /etc/systemd/system/aenv.service > /dev/null <<'UNIT'
[Unit]
Description=AgentENV Server
After=network.target

[Service]
User=aenv
Group=aenv
SupplementaryGroups=kvm
Environment="AENV_HOME_PATH=/var/lib/aenv"
Environment="AENV_CONFIG_PATH=/var/lib/aenv/config/config.toml"
Environment="API_ADDR=0.0.0.0:8000"
ExecStart=/usr/local/bin/server
RuntimeDirectory=aenv
RuntimeDirectoryMode=0750
AmbientCapabilities=CAP_NET_ADMIN CAP_SYS_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN CAP_SYS_ADMIN
NoNewPrivileges=true
UMask=0027
LimitNOFILE=1048576
LimitMEMLOCK=infinity
Restart=always
RestartSec=3
KillMode=process
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

# Enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable --now aenv.service
sudo systemctl status aenv.service --no-pager
EOF
```

## Verify

### Step 7: Verify Server Health and Endpoints

Check that the server responds to local and remote health requests, retrieve the API key, test sandbox listing via curl and the `aenv` CLI:

```bash
# Verify health via SSH on the VM
gcloud compute ssh "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --command='bash -s' <<'EOF'
set -euo pipefail
sleep 5
echo "Checking local /health endpoint:"
curl -fsSL http://127.0.0.1:8000/health
echo ""

API_KEY="$(sudo cat /var/lib/aenv/secrets/api-key)"
echo "Retrieved API key: ${API_KEY:0:8}..."

echo "Checking local /sandboxes endpoint:"
curl -fsSL -H "X-API-Key: ${API_KEY}" http://127.0.0.1:8000/sandboxes
echo ""

echo "Configuring aenv CLI credentials..."
mkdir -p "$HOME/.config/aenv"
cat <<CREDS > "$HOME/.config/aenv/credentials"
url = "http://127.0.0.1:8000"
api_key = "${API_KEY}"
CREDS
chmod 600 "$HOME/.config/aenv/credentials"

echo "Checking aenv list CLI output:"
/usr/local/bin/aenv list
echo ""
EOF

# Verify external HTTP access via the VM public IP
VM_EXTERNAL_IP="$(gcloud compute instances describe "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')"
echo "Testing external connectivity to http://${VM_EXTERNAL_IP}:8000/health..."
curl -fsSL "http://${VM_EXTERNAL_IP}:8000/health"
echo ""
echo "AgentENV server is healthy and accessible at http://${VM_EXTERNAL_IP}:8000"
```

## Teardown

Remove all cloud infrastructure created for this run:

```bash
# Delete Compute Engine VM instance
gcloud compute instances delete "${INSTANCE_NAME}" \
  --project="${PROJECT}" \
  --zone="${ZONE}" \
  --quiet

# Delete firewall rule
gcloud compute firewall-rules delete "${FIREWALL_RULE_NAME}" \
  --project="${PROJECT}" \
  --quiet
```
