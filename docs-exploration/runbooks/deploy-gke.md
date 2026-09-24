# Runbook: Deploy (gke)

Deploy the production-grade AgentENV stack across a Google Kubernetes Engine (GKE) cluster in Google Cloud Platform (GCP) using Kustomize.

---

## What this needs

Can this run in the pod/sandbox?
No. Deploying to GKE requires real cloud infrastructure. The core microVM orchestrator requires nested virtualization (hardware-level `/dev/kvm` access on worker nodes), loading custom host kernel modules (`ublk_drv`), tuning host-level sysctl network and pid parameters, and mounting host paths (`/var/lib/aenv`).

### Required GCP / IAM Permissions
The executing identity requires the following roles and permissions in your active GCP project:
- **Kubernetes Engine Admin (`roles/container.admin`)**:
  - `container.clusters.create` / `container.clusters.get` — to provision and configure GKE clusters.
- **Artifact Registry Administrator (`roles/artifactregistry.admin`)**:
  - `artifactregistry.repositories.create` / `artifactregistry.repositories.write` — to create registry repositories and push AgentENV docker images.
- **Project Owner/Editor (`roles/owner` or `roles/editor`)**:
  - `iam.serviceAccounts.actAs` / `resourcemanager.projects.getIamPolicy` — to bind service account roles.

### Feasibility Checklist (Current Environment)
- [✓] `gcloud` — present
- [✓] `kubectl` — present (with Kustomize support)
- [✓] `make` — present
- [✓] `git` — present
- [✓] `curl` — present
- [✗] `docker` — **MISSING** (Install with `sudo apt-get update && sudo apt-get install -y docker.io` to compile and push images)
- [✗] **GKE Cluster Connectivity** — **MISSING** (No active GKE clusters found in the target region `${REGION}`; retrieve credentials via `gcloud container clusters get-credentials`)

---

## Preconditions

1. **Host OS Kernel (6.8+)**: Worker nodes must run a Linux kernel version 6.8 or newer.
2. **Ubuntu GKE Node Image**: GKE node pools must use Ubuntu (`ubuntu_containerd`) as their OS image, because Google Container-Optimized OS (COS) has a read-only root filesystem and restricts loading kernel modules (like `ublk_drv`) and altering host sysctl parameters.
3. **GKE Node Pool Nested Virtualization**: GCE VM types supporting nested virtualization (e.g., `n2-standard-4` or similar) must be utilized, with nested virtualization explicitly enabled in the node pool configuration.
4. **Host-level Setup (`ublk_drv` & Sysctl)**:
   The `ublk_drv` kernel module and optimal sysctl limits must be applied to all GKE worker nodes. Run this on each node via node-initialization daemonsets, startup scripts, or by manually SSHing and executing:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/kvcache-ai/AgentENV/main/scripts/docker-setup.sh | sudo bash
   ```
5. **Shared Storage & P2P Reachability**:
   A shared POSIXFS or Object Storage Service (OSS) must be configured to persist and exchange sandbox snapshot layers, and worker nodes must be able to communicate Pod-to-Pod via P2P listen addresses.

---

## Steps

### 1. Configure GCP Project Environment
Define your GCP project, region, and GKE cluster variables by sourcing `params.env` (where instance parameters are resolved at plan time from Settings and guidance):
```bash
# Load instance parameters
source params.env

# Confirm environment variables are loaded
echo "Project ID: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "GKE Cluster: ${GKE_CLUSTER}"
echo "Repo Name: ${REPO_NAME}"

gcloud config set project "${PROJECT_ID}"
gcloud config set compute/region "${REGION}"
```

### 2. Connect to the GKE Cluster
Retrieve credentials to authenticate `kubectl` to your GKE cluster:
```bash
gcloud container clusters get-credentials "${GKE_CLUSTER}" --region "${REGION}"
```

### 3. Create Artifact Registry and Configure Docker Authentication
Create an Artifact Registry repository to host the AgentENV container images:
```bash
gcloud artifact repositories create "${REPO_NAME}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="AgentENV Docker Images"

gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

### 4. Build and Push Container Images
Set the target registry image paths, build them using the Makefile, and push them to GAR:
```bash
export REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"
export K8S_RUNTIME_IMAGE="${REGISTRY}/agentenv-runtime:latest"
export K8S_GATEWAY_IMAGE="${REGISTRY}/agentenv-gateway:latest"
export K8S_SCHEDULER_IMAGE="${REGISTRY}/agentenv-scheduler:latest"

# Build images directly with custom tags
make k8s-build

# Push images to GAR
docker push "${K8S_RUNTIME_IMAGE}"
docker push "${K8S_GATEWAY_IMAGE}"
docker push "${K8S_SCHEDULER_IMAGE}"
```

### 5. Update Kustomize Image References
Configure Kustomize to use the newly pushed GAR image paths:
```bash
# Update Kustomization image paths in-place
sed -i "s#newName: agentenv-gateway#newName: ${K8S_GATEWAY_IMAGE}#" deploy/k8s/base/kustomization.yaml
sed -i "s#newName: agentenv-scheduler#newName: ${K8S_SCHEDULER_IMAGE}#" deploy/k8s/base/kustomization.yaml
sed -i "s#newName: agentenv-runtime#newName: ${K8S_RUNTIME_IMAGE}#" deploy/k8s/base/kustomization.yaml
```

### 6. Apply Manifests to the GKE Cluster
Execute the helper script to render, bootstrap the `AENV_API_KEY` secret, and apply the configuration.
By default, this deploys to the `agentenv-system` namespace.
```bash
# (Optional) Deploy with a specific sandbox proxy domain
export SANDBOX_PROXY_DOMAINS="sandbox.example.com"

# Deploy to the cluster
make k8s-apply
```

---

## Verify

### 1. Confirm Workload Statuses
Verify that all deployment and daemonset pods are running and healthy:
```bash
kubectl get pods -n agentenv-system
```
**Expected output:**
- `agentenv-gateway-*` — 1/1 Running
- `agentenv-scheduler-*` — 1/1 Running (Note: The scheduler must run as a single replica because sandbox bindings are in-memory)
- `agentenv-node-*` — Running on every worker node (Privileged runtime pod running in DaemonSet)

### 2. Extract the Generated API Key
Retrieve the cryptographically secure API key generated during deployment from the Kubernetes secret:
```bash
export AENV_API_KEY=$(kubectl -n agentenv-system get secret agentenv-auth \
  -o go-template='{{index .data "AENV_API_KEY" | base64decode}}')
echo "API Key: ${AENV_API_KEY}"
```

### 3. Verify Health and Node Discovery via Gateway Ingress
The gateway service is `ClusterIP` by default. Expose it or access it using port-forwarding:
```bash
kubectl port-forward svc/agentenv-gateway 8000:8000 -n agentenv-system &
sleep 2

# Verify health endpoint
curl -fsS http://127.0.0.1:8000/health

# Verify node discovery (must show active node daemon statuses matching GKE nodes)
curl -fsS -H "X-API-Key: ${AENV_API_KEY}" http://127.0.0.1:8000/nodes
```

---

## Teardown

To tear down the AgentENV components and delete all created Kubernetes resources from GKE:
```bash
make k8s-delete
```
*(Optional: Delete the Artifact Registry repository and GKE cluster if they are no longer needed)*
```bash
gcloud artifact repositories delete "${REPO_NAME}" --location="${REGION}" --quiet
gcloud container clusters delete "${GKE_CLUSTER}" --region="${REGION}" --quiet
```
