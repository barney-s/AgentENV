# Runbook: Deploy (in-pod)

Deploy the multi-node simulated AgentENV stack on a local machine or single-node environment using Docker Compose.

---

## What this needs

Can this run in the pod/sandbox?
Yes, this runbook executes entirely on a single Linux host using standard container virtualization. It runs a multi-node simulation (gateway, scheduler, and multiple AgentENV nodes) without requiring real cloud infrastructure or a Kubernetes cluster.

However, the backend microVM containers need host-level access to `/dev/kvm` to run standard KVM. If `/dev/kvm` is missing on your host, you must either enable nested virtualization, use a physical virtualization mode, or simulate it.

### Required Host/IAM Permissions
- No cloud IAM permissions are required for this local in-pod deployment.
- Local user must have `sudo` privileges to configure the local network interface and KVM permissions.

### Feasibility Checklist (Current Environment)
- [✓] `make` — present at `/usr/bin/make`
- [✓] `git` — present
- [✓] `curl` — present
- [✗] `docker` — **MISSING** (Install on Linux with: `sudo apt-get update && sudo apt-get install -y docker.io`)
- [✗] `docker compose` — **MISSING** (Install with: `sudo apt-get install -y docker-compose-v2`)
- [✗] `/dev/kvm` — **MISSING** (Host virtualization support is missing or nested virtualization is disabled)

---

## Preconditions

1. Ensure your host machine runs a modern Linux kernel (6.8+ is recommended).
2. The user running the docker commands must be in the `docker` group, or commands must be run as `root`.
3. Upstream DNS must be reachable; make sure `/run/systemd/resolve/resolv.conf` or `/etc/resolv.conf` contains valid non-loopback nameservers.

---

## Steps

### 1. Configure Host Virtualization & Network Access
Initialize the required TAP adapters, bridge interfaces, and group permissions on the host:
```bash
sudo bash scripts/docker-setup.sh
```

### 2. Start the Cluster Stack
Use the Makefile to build the runtime, gateway, and scheduler images and spin them up under Docker Compose:
```bash
make deploy-up
```
*(Note: This uses `deploy/docker-compose.yml` to start the gateway, scheduler, `agentenv-a`, and `agentenv-b` containers. The build stage compiles the Rust and Go tools inside the container; host toolchains are not required.)*

---

## Verify

### 1. Probe the Public Gateway Health
Verify that the API gateway is listening and healthy:
```bash
curl -fsS http://127.0.0.1:8000/health
```
**Expected response:**
`OK` (or similar HTTP 200 health response)

### 2. Extract the Generated API Key
On first boot, the runtime nodes generate a shared API key inside the shared volume. Extract it to authenticate your requests:
```bash
export AENV_API_KEY="$(docker compose -f deploy/docker-compose.yml exec -T agentenv-a cat /workspace/env/secrets/api-key)"
echo "Extracted API Key: ${AENV_API_KEY}"
```

### 3. Verify Cluster Nodes via Authenticated Gateway Request
Use the extracted API key to list active runtime nodes registered with the scheduler:
```bash
curl -fsS -H "X-API-Key: ${AENV_API_KEY}" http://127.0.0.1:8000/nodes
```
**Expected response:** A JSON array displaying metadata of active nodes (`agentenv-a`, `agentenv-b`).

### 4. Verify Internal Connectivity
Verify that the runtime backend can resolve internal traffic and communicate with the gateway:
```bash
docker compose -f deploy/docker-compose.yml exec -T agentenv-a curl -fsS http://127.0.0.1:8000/health
```

---

## Teardown

To shut down and destroy the simulated cluster, execute:
```bash
make deploy-down
```
*(Note: To remove the shared API secrets and storage volumes as well, run `docker compose -f deploy/docker-compose.yml down -v --remove-orphans`)*
