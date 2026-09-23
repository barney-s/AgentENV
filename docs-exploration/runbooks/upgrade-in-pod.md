# Runbook: Upgrade (in-pod)

Upgrade a running multi-node simulated AgentENV stack on a single Linux host under Docker Compose.

---

## What this needs

Can this run in the pod/sandbox?
Yes, this runbook executes entirely on a single Linux host using standard container virtualization. It rebuilds and redeploys the Docker Compose services without requiring real cloud infrastructure or a Kubernetes cluster.

### Required Host/IAM Permissions
- No cloud IAM permissions are required.
- Local user must have `sudo` privileges to configure the host's networking or KVM configurations.

### Feasibility Checklist (Current Environment)
- [✓] `make` — present at `/usr/bin/make`
- [✓] `git` — present
- [✓] `curl` — present
- [✗] `docker` — **MISSING** (Install on Linux with: `sudo apt-get update && sudo apt-get install -y docker.io`)
- [✗] `docker compose` — **MISSING** (Install with: `sudo apt-get install -y docker-compose-v2`)
- [✗] `/dev/kvm` — **MISSING** (Host virtualization support is missing or nested virtualization is disabled)

---

## Preconditions

1. An existing AgentENV stack is already deployed and running on the host (as set up by the `deploy-in-pod` runbook).
2. Existing API keys and state are located in the Docker volume `agentenv-auth`. We want to preserve this secret state so clients do not have to be reconfigured.

---

## Steps

### 1. Fetch Latest Code
Pull the latest updates from the source repository:
```bash
git fetch origin && git pull
```

### 2. Rebuild the Images
Rebuild the container images (runtime, gateway, scheduler) incorporating the new code changes. The Rust and Go source files will compile inside the multi-stage Docker builds:
```bash
make deploy-build
```

### 3. Apply the Rolling Upgrade
Deploy the newly built images. Docker Compose will automatically detect changed images and perform a rolling recreation of only the updated containers. It preserves persistent volume mounts, which means your generated `api-key` and auth state are retained:
```bash
make deploy-up
```
*(Alternative: If you want to force recreate all containers without losing data, run `make deploy-down && make deploy-up`.)*

---

## Verify

### 1. Verify Gateway Health
Ensure that the API gateway is online and responding post-upgrade:
```bash
curl -fsS http://127.0.0.1:8000/health
```
**Expected response:** `OK`

### 2. Verify Client Auth Persistence
Confirm that the previously generated API key is still valid and has not been overwritten:
```bash
export AENV_API_KEY="$(docker compose -f deploy/docker-compose.yml exec -T agentenv-a cat /workspace/env/secrets/api-key)"
curl -fsS -H "X-API-Key: ${AENV_API_KEY}" http://127.0.0.1:8000/nodes
```
**Expected response:** A JSON list of active nodes (`agentenv-a`, `agentenv-b`), confirming that the gateway can read the preserved secret and that runtime nodes have re-registered.

---

## Teardown

To shut down and destroy the simulated cluster:
```bash
make deploy-down
```
*(Note: To clean up all images, networks, and the auth volume, run `docker compose -f deploy/docker-compose.yml down -v --rmi all --remove-orphans`)*
