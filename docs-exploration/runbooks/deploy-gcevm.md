# Runbook: Deploy (gcevm)

Deploy the AgentENV stack directly from source on a single Google Compute Engine (GCE) VM using nested virtualization and manual compilation.

---

## What this needs

Can this run in the pod/sandbox?
No. Deploying AgentENV directly on a host requires real cloud infrastructure. Specifically, a GCE VM is used to satisfy the hardware-level `/dev/kvm` requirement (via nested virtualization) and to load kernel modules like `ublk_drv` natively on a real OS kernel. This cannot run inside the default non-privileged local pod/sandbox.

### Required GCP / IAM Permissions
The executing identity requires the following roles and permissions in your active GCP project to manage the VM:
- **Compute Instance Admin (`roles/compute.instanceAdmin`)**:
  - `compute.instances.create` / `compute.instances.get` / `compute.instances.delete` — to provision, query, and tear down the GCE VM instance.
  - `compute.networks.use` / `compute.subnetworks.use` — to attach the instance to VPC networks.
- **Service Account User (`roles/iam.serviceAccountUser`)**:
  - `iam.serviceAccounts.actAs` — to attach and execute as the default or custom service account on the VM.
- **Project Owner/Editor (`roles/owner` or `roles/editor`)**:
  - To perform administrative and management actions across the Compute Engine APIs.

### Feasibility Checklist (Current Environment)
- [✓] **IAM Owner/Editor Role** — **GRANTED** (The active credentials have `roles/owner` / `roles/editor` on the GCP project `${PROJECT_ID}`)
- [✓] `gcloud` — present at `/usr/bin/gcloud`
- [✓] `make` — present at `/usr/bin/make`
- [✓] `git` — present at `/usr/bin/git`
- [✓] `curl` — present at `/usr/bin/curl`

---

## Preconditions

Ensure you have your GCP project, zone, and GCE VM configuration variables ready. You can define them in a `params.env` file or export them directly in your environment:

1. **`PROJECT_ID`**: Your active GCP project ID (e.g., `barni-cnrm-20260529`).
2. **`ZONE`**: The GCP compute zone (e.g., `us-central1-a` or `us-east1-b`).
3. **`VM_NAME`**: The name of the GCE VM instance (e.g., `agentenv-manual-host`).
4. **`MACHINE_TYPE`**: GCE machine type (e.g., `n2-standard-4`). Must be Intel processor family (e.g., N2, N1, C2, C3) to support nested virtualization.
5. **`IMAGE_FAMILY`**: Ubuntu 24.04 LTS (`ubuntu-2404-lts-amd64`) to get kernel 6.8+ natively out-of-the-box.
6. **`IMAGE_PROJECT`**: Ubuntu OS images project (`ubuntu-os-cloud`).
7. **Boot Disk Space**: A boot disk size of at least **50GB** is required because building the full AgentENV Rust workspace (including the large RocksDB C++ dependencies) requires substantial scratch space and exceeds the default GCE 10GB limit.

---

## Steps

### 1. Configure GCP Project Environment
Define your GCP environment parameters by sourcing `params.env` (where instance parameters are resolved at plan time from Settings and guidance):
```bash
# Load instance parameters
source params.env

# Confirm environment variables are loaded
echo "Project ID: ${PROJECT_ID}"
echo "Zone: ${ZONE}"
echo "VM Name: ${VM_NAME}"

gcloud config set project "${PROJECT_ID}"
gcloud config set compute/zone "${ZONE}"
```

### 2. Create GCE VM with Nested Virtualization
To run Firecracker microVMs inside guest environments, standard KVM access is required. We must enable nested virtualization on the L1 GCE VM.
```bash
gcloud compute instances create "${VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --image-family="${IMAGE_FAMILY}" \
    --image-project="${IMAGE_PROJECT}" \
    --enable-nested-virtualization \
    --boot-disk-size=50GB \
    --metadata=startup-script="#!/bin/bash
set -euo pipefail
# Ensure compilation-essential and runtime dependencies are ready
apt-get update
apt-get install -y git build-essential pkg-config libssl-dev protobuf-compiler clang libclang-dev libprotobuf-dev ca-certificates curl e2fsprogs iproute2 iptables jq sudo umoci zstd
echo 'done' > /var/run/startup-script-finished
"
```

### 3. SSH into the GCE VM
Once the instance is provisioned and booted up, SSH directly into it:
```bash
gcloud compute ssh "${VM_NAME}" --zone="${ZONE}"
```

### 4. Install Rust Toolchain
Once connected inside the GCE VM, install the latest stable Rust toolchain via rustup:
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
```

### 5. Configure Host Virtualization & Kernel Tuning
To prepare the VM host for running ublk devices, Firecracker, and high-performance microVM networking, load the necessary kernel modules and sysctl tuning configurations:
```bash
# Clone AgentENV
git clone https://github.com/kvcache-ai/AgentENV.git
cd AgentENV

# Configure overlaybd default configuration path
sudo mkdir -p /etc/overlaybd
sudo sh -c "printf '{}\n' > /etc/overlaybd/overlaybd.json"

# Run host-setup script to load ublk_drv and apply sysctl tunings
sudo bash scripts/docker-setup.sh
```
Verify that KVM is available and that your user can access `/dev/kvm`:
```bash
ls -l /dev/kvm
# Output should show: crw-rw---- 1 root kvm ...
```

### 6. Compile AgentENV from Source
Compile the AgentENV binary targets in Release mode:
```bash
# Compile all crates in release mode
make release

# Install the custom CLI (aenv) globally
sudo make install-aenv
```

### 7. Run the AgentENV Server
Run the compiled server bare-metal. The Makefile targets use `scripts/run-with-capabilities.sh` under the hood to run the server with only `CAP_NET_ADMIN` and `CAP_SYS_ADMIN` ambient capabilities (via `setpriv`), avoiding running as full root.
```bash
# Start the server (Release build) on port 8000
API_ADDR=0.0.0.0:8000 make start-server-release
```
*(Note: On first start, the server will automatically download necessary runtime assets such as the Firecracker binary, guest kernel, and rootfs, and generate a secure API key under `/var/lib/aenv/secrets/api-key`.)*

---

## Verify

### 1. Probe the Public Server/Gateway Health
In a new SSH terminal session on the GCE VM (or from outside if port 8000 is open in your VPC firewalls), probe the local server's health:
```bash
curl -fsS http://127.0.0.1:8000/health
```
**Expected response:**
`OK`

### 2. Extract the Generated API Key
Retrieve the secure API key from the local state directory:
```bash
export AENV_API_KEY="$(sudo cat /var/lib/aenv/secrets/api-key)"
echo "Extracted API Key: ${AENV_API_KEY}"
```

### 3. Verify the Sandboxes Endpoint
Query the sandboxes endpoint using the extracted API key:
```bash
curl -fsS -H "X-API-Key: ${AENV_API_KEY}" http://127.0.0.1:8000/sandboxes
```
**Expected response:**
`[]` (An empty JSON array indicating no active sandboxes running)

---

## Teardown

### 1. Stop the Running Server
In the SSH terminal session running the server, press `Ctrl+C` to terminate the process cleanly.

### 2. Delete the GCE VM Instance
On your local workstation or CI terminal, terminate and delete the GCE VM:
```bash
gcloud compute instances delete "${VM_NAME}" --zone="${ZONE}" --quiet
```
