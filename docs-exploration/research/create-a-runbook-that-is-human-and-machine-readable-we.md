# AgentENV GCP Deployment: Architecture Research, Cloud Provisioning, and Runbook

This document details the architecture, GCP resource requirements, automated deployment specifications, and manual execution steps for compiling and running [AgentENV](https://github.com/kvcache-ai/AgentENV) from source on Google Cloud Platform (GCP) following the [Manual Compile Deployment Guide](https://kvcache-ai.github.io/AgentENV/latest/deployment/manual-compile.html).

---

## 1. Context and Objective

AgentENV is an execution environment for AI agents that runs sandboxes inside isolated Firecracker microVMs backed by user-space block devices (`ublk`) and OverlayBD rootfs layers.

The objective was to:
1. Investigate the codebase requirements for running AgentENV via manual compilation on a Linux host.
2. Determine the exact GCP machine type, OS image, and kernel capabilities required.
3. Provision the necessary GCP infrastructure (VPC firewall rules and Compute Engine instance with nested virtualization enabled).
4. Provide both a machine-readable runbook specification and a human-readable operational guide.
5. Identify open items and unresolved configurations.

---

## 2. Codebase Investigation & Technical Flow Tracing

An inspection of the checked-out repository reveals several strict hardware, kernel, privilege, and software dependencies.

### 2.1 Virtualization & Hardware Acceleration (`/dev/kvm`)

AgentENV relies on Linux KVM for hardware-accelerated virtualization:
- **Device Access**: `src/setup/kvm.rs:10-16` validates that `/dev/kvm` can be opened with read and write permissions (`OpenOptions::new().read(true).write(true).open("/dev/kvm")`).
- **Virtualization Mode**: `src/setup/kvm.rs:42-60` validates that when `virtualization_mode` is set to `kvm`, the `kvm_pvm` kernel module must not be loaded (`validate_mode()`).
- **Group Membership**: `src/setup/kvm.rs:18-40` implements `add_user_to_group()`, adding the runtime service account to the `kvm` group via `usermod -aG kvm <user>`.
- **GCP Implication**: Because AgentENV runs inside a GCP Compute Engine virtual machine, the VM must have hardware-assisted nested virtualization enabled (`--enable-nested-virtualization`) to expose Intel VMX (`vmx`) or AMD SVM (`svm`) flags and populate `/dev/kvm`.

### 2.2 Storage Subsystem (`ublk` & OverlayBD)

MicroVM root filesystems and writable scratch layers are managed through Linux user-space block devices (`ublk`) combined with OverlayBD:
- **Kernel Module**: `src/setup/ublk.rs:56-66` checks for `ublk_drv`. If not loaded, it attempts to load it via `load_ublk_module()`, installs `/etc/modules-load.d/aenv-ublk.conf`, and configures persistent udev rules in `/etc/udev/rules.d/99-agentenv-ublk.rules` granting group `0660` permissions to the runtime group for `/dev/ublk-control`, `/dev/ublkc*`, and `/dev/ublkb*`.
- **Legacy Limit Override**: `scripts/install.sh:248-251` configures `/etc/modprobe.d/aenv-ublk.conf` with `options ublk_drv ublks_max=4096`.
- **Device Verification**: `src/setup/ublk.rs:68-76` enforces that `ublk_drv` is loaded and `/dev/ublk-control` can be opened read/write by the non-root runtime account.
- **Kernel Module Source**: `src/setup/ublk.rs:88-108` queries the host package manager for `linux-modules-extra-$(uname -r)` if `ublk_drv` is not found.
- **Daemon Binary**: `Makefile:139-147` defines `install-ublk`, which builds `uvm-ublk-daemon` (`storage/ublk-daemon`) and copies it to `/var/lib/aenv/ublk/uvm-ublk-daemon` (`UVM_UBLK_DAEMON_INSTALL_PATH`).

### 2.3 Kernel Network Capacity & Host Sysctls

Running multiple concurrent microVM sandboxes requires scaling host network limits:
- **Tuning Parameters**: `src/setup/network_capacity.rs:15-60` defines required sysctl thresholds:
  - `net.ipv4.ip_forward = 1` (MANDATORY: `src/setup/mod.rs:154-158` terminates startup if `/proc/sys/net/ipv4/ip_forward` != `1`).
  - `net.ipv4.neigh.default.gc_thresh3 = 16384` (ARP table GC threshold 3).
  - `net.ipv4.neigh.default.gc_thresh2 = 8192` (ARP table GC threshold 2).
  - `net.ipv4.neigh.default.gc_thresh1 = 4096` (ARP table GC threshold 1).
  - `net.netfilter.nf_conntrack_max = 1048576` (Connection tracking for thousands of sandboxes).
  - `kernel.pid_max = 4194304` (PID exhaustion mitigation).
  - `fs.inotify.max_user_instances = 8192` (Firecracker/envd inotify watches).
- **Persistence**: `src/setup/network_capacity.rs:62-71` persists these values to `/etc/sysctl.d/99-aenv.conf`.
- **File Descriptor Limit**: `src/setup/mod.rs:149-160` enforces `RLIMIT_NOFILE >= 65536`.

### 2.4 Process Privileges & Capabilities

AgentENV runs as an unprivileged service account while executing privileged namespace and network operations:
- **Capability Requirements**: `src/privileges.rs:26-48` enforces that `CAP_NET_ADMIN` and `CAP_SYS_ADMIN` are present in effective or permitted/delegable capability sets.
- **Capability Execution Wrapper**: `scripts/run-with-capabilities.sh:65-102` sets `ulimit -l unlimited` (required for io_uring and ublk locked memory allocation) and executes the server under `setpriv --ambient-caps=-all,+net_admin,+sys_admin --bounding-set=-all,+net_admin,+sys_admin --nnp`.
- **Systemd Service Setup**: `scripts/install.sh:372-392` configures `AmbientCapabilities=CAP_NET_ADMIN CAP_SYS_ADMIN`, `LimitMEMLOCK=infinity`, `LimitNOFILE=1048576`, and `KillMode=process` (preventing systemd from killing active Firecracker processes upon server exit).

### 2.5 Build Dependencies & Protobuf Generation

- **Protobuf Compiler**: `build.rs:10-25` invokes `tonic_prost_build::compile_protos()` on `services/api/proto/scheduler.proto` and `src/image/*.proto`. This requires `protoc` to be installed and available in `$PATH`.
- **Runtime Dependencies**: `config/deps_manifest.toml:42-70` lists runtime commands probed by `src/setup/packages.rs`: `curl`, `debugfs`, `ip`, `iptables-restore`, `iptables-save`, `jq`, `mkfs.ext4`, `resize2fs`, `sudo`, `umoci`, `zstd`, `ca-certificates`.
- **Downloaded Assets**: On initial startup, `src/setup/deps.rs:105-135` automatically downloads:
  - Firecracker KVM binary: `v1.15.1-patch-v1`
  - Guest kernel: `vmlinux-6.1.175`
  - Tools rootfs: `ghcr.io/kvcache-ai/agentenv-tools:0.1.1`
  - OverlayBD CLI tools: `v1.0.18-aenv.1`
  - Regclient binary: `regctl` (`v0.11.5`)

### 2.6 Server Lifecycle & API Authentication

- **API Key Management**: `src/api_key.rs:20-86` reads the API key from `/run/secrets/api-key` or `$AENV_HOME/secrets/api-key`. If no key exists, it generates a cryptographically secure key prefixed with `e2b_` and saves it with permissions `0600` (`src/managed_secret.rs:41-52`).
- **HTTP Routing**: `src/api/server.rs:40-48` configures Axum routes.
- **Unauthenticated Endpoints**: `src/api/impls/auth.rs:54-56` allows `/health` and `/metrics` without authentication.
- **Health Check**: `src/api/impls/mod.rs:172-180` handles `/health`, returning `HTTP 204 No Content`.
- **Authenticated Endpoints**: All sandbox and template management endpoints (`/sandboxes`, `/templates`, `/snapshots`, `/volumes`) require the `X-API-Key` header.
- **Listening Address**: `docs/src/deployment/manual-compile.md:37` specifies controlling the host binding via the `API_ADDR` environment variable (e.g., `API_ADDR=0.0.0.0:8000`).

---

## 3. GCP VM Architecture & Sizing Comparison

| Machine Family | Sample Machine Type | vCPU / RAM | Nested Virt Support | Viability for AgentENV Manual Compile |
|---|---|---|---|---|
| **N2 (Intel Cascade Lake / Ice Lake)** | `n2-standard-8` | 8 vCPU / 32 GB | **Yes** (`--enable-nested-virtualization`) | **Selected**. Fast compilation of the multi-crate Rust workspace, hardware VMX assist, ample memory for cargo build caches and microVM memory allocations. |
| **N2 (Intel Cascade Lake / Ice Lake)** | `n2-standard-4` | 4 vCPU / 16 GB | **Yes** (`--enable-nested-virtualization`) | Viable minimum for light testing; compile times are approximately 2-3x longer. |
| **N2D (AMD EPYC Milan / Rome)** | `n2d-standard-8` | 8 vCPU / 32 GB | **Yes** (`--enable-nested-virtualization`) | Viable AMD SVM alternative. |
| **C3 (Intel Sapphire Rapids)** | `c3-standard-8` | 8 vCPU / 32 GB | **Yes** | High compute performance, but requires newer Hyperdisk storage and higher cost. |
| **N1 (Intel Skylake / Broadwell)** | `n1-standard-8` | 8 vCPU / 30 GB | **Yes** (with `min-cpu-platform`) | Slower compilation; older architecture. |
| **E2 (Shared Core / Standard)** | `e2-standard-4` | 4 vCPU / 16 GB | **No** | **Incompatible**. GCP does not permit nested virtualization on E2 machine types. Cannot expose `/dev/kvm`. |
| **T2D / T2A (Tau AMD / ARM)** | `t2d-standard-8` | 8 vCPU / 32 GB | **No** | **Incompatible**. Nested virtualization not supported. |

### Operating System Selection

- **Image**: `ubuntu-os-cloud / ubuntu-2404-lts-amd64` (Ubuntu 24.04 LTS Noble Numbat).
- **Reasoning**: AgentENV mandates **Linux kernel 6.8+** (`docs/src/deployment/manual-compile.md:7`). Ubuntu 24.04 LTS ships natively with Linux kernel `6.8.0-xx-generic`, fulfilling the prerequisite out of the box.

---

## 4. Provisioned GCP Resources

The following GCP resources were provisioned in project `barni-cnrm-20260529`:

### 4.1 Firewall Rule: `allow-agentenv-api`

- **Network**: `default`
- **Direction**: `INGRESS`
- **Priority**: `1000`
- **Action**: `ALLOW`
- **Protocol & Port**: `tcp:8000`
- **Source Range**: `0.0.0.0/0`
- **Target Tag**: `agentenv`
- **Command Used**:
  ```bash
  gcloud compute firewall-rules create allow-agentenv-api \
    --project=barni-cnrm-20260529 \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:8000 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=agentenv \
    --description="Allow AgentENV HTTP API on port 8000"
  ```

### 4.2 Compute Engine Instance: `agentenv-host-1`

- **Zone**: `us-central1-a`
- **Machine Type**: `n2-standard-8` (8 vCPUs, 32 GB RAM)
- **Nested Virtualization**: Enabled (`--enable-nested-virtualization`)
- **Boot Disk**: 100 GB `pd-balanced`
- **OS Image Family**: `ubuntu-2404-lts-amd64` (Project: `ubuntu-os-cloud`)
- **Network Tag**: `agentenv`
- **Status**: `RUNNING`
- **Internal IP**: `10.128.0.48`
- **External IP**: `34.59.146.51`
- **Command Used**:
  ```bash
  gcloud compute instances create agentenv-host-1 \
    --project=barni-cnrm-20260529 \
    --zone=us-central1-a \
    --machine-type=n2-standard-8 \
    --enable-nested-virtualization \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=100GB \
    --boot-disk-type=pd-balanced \
    --tags=agentenv \
    --description="AgentENV host with KVM nested virtualization for manual compile"
  ```

---

## 5. Machine-Readable Runbook Specification

### 5.1 Declarative Deployment Schema

```yaml
apiVersion: runbook.agentenv.ai/v1alpha1
kind: ManualCompileDeployment
metadata:
  name: agentenv-manual-compile-gcp
  version: "0.1.0"
  targetProject: "barni-cnrm-20260529"
spec:
  infrastructure:
    computeInstance:
      name: "agentenv-host-1"
      zone: "us-central1-a"
      machineType: "n2-standard-8"
      nestedVirtualization: true
      bootDisk:
        sizeGb: 100
        type: "pd-balanced"
      image:
        project: "ubuntu-os-cloud"
        family: "ubuntu-2404-lts-amd64"
      networkTags:
        - "agentenv"
    firewall:
      name: "allow-agentenv-api"
      network: "default"
      allow:
        - protocol: "tcp"
          ports: ["8000"]
      targetTags: ["agentenv"]
  build:
    gitRepository: "https://github.com/kvcache-ai/AgentENV.git"
    gitBranch: "main"
    rustToolchain: "stable"
    buildCommands:
      - "make release"
  provisioning:
    hostSetupCommand: "sudo ./target/release/server --setup-host --runtime-user ubuntu --runtime-group ubuntu"
    ublkInstallCommand: "sudo make install-ublk PROFILE=release"
  runtime:
    apiAddress: "0.0.0.0:8000"
    homePath: "/var/lib/aenv"
    configPath: "config/default.toml"
    healthEndpoint: "http://127.0.0.1:8000/health"
    sandboxesEndpoint: "http://127.0.0.1:8000/sandboxes"
```

### 5.2 Automated Host Setup Script (`deploy_agentenv.sh`)

Save this script on `agentenv-host-1` as `/home/ubuntu/deploy_agentenv.sh` and execute with `bash deploy_agentenv.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "==> 1. Verifying hardware virtualization support (/dev/kvm)..."
if [[ ! -e /dev/kvm ]]; then
    echo "ERROR: /dev/kvm is missing. Verify that nested virtualization is enabled on this VM." >&2
    exit 1
fi
echo "KVM acceleration detected."

echo "==> 2. Installing system build dependencies and runtime packages..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential \
    clang \
    libclang-dev \
    protobuf-compiler \
    libprotobuf-dev \
    pkg-config \
    libssl-dev \
    git \
    curl \
    jq \
    umoci \
    zstd \
    e2fsprogs \
    iproute2 \
    iptables \
    ca-certificates \
    linux-modules-extra-gcp || true

echo "==> 3. Installing Rust stable toolchain..."
if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    source "$HOME/.cargo/env"
else
    rustup default stable
fi

echo "==> 4. Cloning AgentENV repository..."
if [[ ! -d "AgentENV" ]]; then
    git clone https://github.com/kvcache-ai/AgentENV.git
fi
cd AgentENV

echo "==> 5. Building release binaries (make release)..."
make release

echo "==> 6. Running host-level provisioning (--setup-host)..."
CURRENT_USER="$(id -un)"
CURRENT_GROUP="$(id -gn)"
sudo ./target/release/server --setup-host --runtime-user "${CURRENT_USER}" --runtime-group "${CURRENT_GROUP}"

echo "==> 7. Installing uvm-ublk-daemon to /var/lib/aenv/ublk..."
sudo make install-ublk PROFILE=release

echo "==> 8. Adding current user to kvm group..."
sudo usermod -aG kvm "${CURRENT_USER}"

echo "Setup completed successfully. Start the server with:"
echo "    cd $(pwd)"
echo "    API_ADDR=0.0.0.0:8000 make start-server-release"
```

---

## 6. Human-Readable Operational Guide

### Step 1: Connect to the GCP VM

SSH into the provisioned instance using `gcloud`:
```bash
gcloud compute ssh agentenv-host-1 --zone=us-central1-a --project=barni-cnrm-20260529
```

### Step 2: Validate Prerequisites on the Host

Confirm that KVM and kernel parameters match requirements:
```bash
# Check CPU virtualization extensions
egrep -c '(vmx|svm)' /proc/cpuinfo   # Must return >= 1

# Check /dev/kvm existence
ls -la /dev/kvm                     # Must show character device owned by group kvm

# Confirm Linux kernel 6.8+
uname -r
```

### Step 3: Install Compilation Packages

```bash
sudo apt-get update -y
sudo apt-get install -y \
    build-essential \
    clang \
    libclang-dev \
    protobuf-compiler \
    libprotobuf-dev \
    pkg-config \
    libssl-dev \
    git \
    curl \
    jq \
    umoci \
    zstd \
    e2fsprogs \
    iproute2 \
    iptables \
    ca-certificates

# Install Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
```

### Step 4: Clone and Compile

```bash
git clone https://github.com/kvcache-ai/AgentENV.git
cd AgentENV

# Compile all workspace binaries in release mode
make release
```

### Step 5: Provision Host Environment

Before running the server unprivileged, run the host setup command as root to initialize `/dev/kvm` permissions, load `ublk_drv`, create udev rules, and apply network sysctls:
```bash
sudo ./target/release/server --setup-host --runtime-user "$USER" --runtime-group "$(id -gn)"
sudo make install-ublk PROFILE=release
sudo usermod -aG kvm "$USER"
newgrp kvm
```

### Step 6: Start the Server

```bash
API_ADDR=0.0.0.0:8000 make start-server-release
```

On first startup:
- The capability runner (`scripts/run-with-capabilities.sh`) sets `ulimit -l unlimited` and elevates `CAP_NET_ADMIN` and `CAP_SYS_ADMIN`.
- Firecracker (`v1.15.1-patch-v1`), guest kernel (`vmlinux-6.1.175`), and the tools drive are downloaded into `/var/lib/aenv/deps`.
- An API key is generated and stored in `/var/lib/aenv/secrets/api-key`.
- The HTTP server starts listening on `0.0.0.0:8000`.

### Step 7: Verify Service Health

From a second terminal session:
```bash
# Retrieve generated API key
export AENV_API_KEY="$(sudo cat /var/lib/aenv/secrets/api-key)"

# Verify unauthenticated health probe (HTTP 204)
curl -i http://127.0.0.1:8000/health

# Verify authenticated sandbox listing (HTTP 200)
curl -i -H "X-API-Key: ${AENV_API_KEY}" http://127.0.0.1:8000/sandboxes

# Remote external health check
curl -i http://34.59.146.51:8000/health
```

---

## 7. Troubleshooting Matrix

| Symptom / Error | Code Reference | Root Cause & Remediation |
|---|---|---|
| `KVM device not found (/dev/kvm)` | `src/setup/kvm.rs:48-53` | The VM lacks nested virtualization. Ensure instance was created with `--enable-nested-virtualization` on an N2, N2D, or C3 machine type. |
| `/dev/kvm is not accessible for read/write` | `src/setup/kvm.rs:56-60` | Current user lacks permissions. Run `sudo usermod -aG kvm $USER` and start a new shell session (`newgrp kvm`). |
| `ublk_drv is not loaded; run server --setup-host as root` | `src/setup/ublk.rs:69-72` | The `ublk_drv` kernel module is not loaded. Execute `sudo modprobe ublk_drv`. If module is missing, run `sudo apt-get install -y linux-modules-extra-gcp`. |
| `failed to raise locked-memory ulimit` or `io_uring` register failure | `scripts/run-with-capabilities.sh:65-72` | Process cannot lock memory for ublk zero-copy buffers. Run `ulimit -l unlimited` or configure `LimitMEMLOCK=infinity` in systemd. |
| `AENV runtime is missing required Linux capabilities` | `src/privileges.rs:38-44` | Server launched without ambient capabilities. Launch via `make start-server-release` or ensure systemd unit includes `AmbientCapabilities=CAP_NET_ADMIN CAP_SYS_ADMIN`. |
| `host IPv4 forwarding is disabled` | `src/setup/mod.rs:154-158` | Kernel parameter `/proc/sys/net/ipv4/ip_forward` is `0`. Run `sudo sysctl -w net.ipv4.ip_forward=1` and persist via `/etc/sysctl.d/99-aenv.conf`. |
| `Could not find 'protoc'` during build | `build.rs:10-25` | Protocol buffer compiler is missing. Install with `sudo apt-get install -y protobuf-compiler`. |

---

## 8. Open Issues & Unresolved Areas

1. **SSH Key Injection in Automated Session**: Connecting to `agentenv-host-1` via `gcloud compute ssh` during this investigation prompted interactively for a local SSH key path in the CLI container, which was aborted to prevent hanging. An automated non-interactive runner requires provisioning a pre-seeded public key in instance metadata.
2. **Persistent Remote Storage Backend**: The current manual-compile configuration defaults to local disk for image caching and OverlayBD commits (`config/default.toml:57`). Production shared snapshots require configuring an external S3 or OSS bucket (`src/cfg.rs`, `src/setup/deps.rs`), which was not provisioned.
3. **Multi-Node Cluster Scheduling**: The manual compile workflow targets a single-node host. Enabling distributed multi-node coordination requires configuring the P2P transport (`iroh`), deploying the AgentENV scheduler (`services/scheduler`), and deploying the gateway proxy (`services/gateway`).
