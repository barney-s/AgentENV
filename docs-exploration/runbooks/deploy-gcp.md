# Runbook: Deploy (gcp)

Deploy the production-grade AgentENV stack across a Google Kubernetes Engine (GKE) cluster in Google Cloud Platform (GCP).

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
- [✓] **IAM Owner Role** — **GRANTED** (The current identity `cnrm-barni-1.svc.id.goog` has `roles/owner` on GCP project `barni-cnrm-20260529`)
- [✓] `gcloud` — present at `/usr/bin/gcloud`
- [✓] `kubectl` — present at `/usr/bin/kubectl`
- [✓] `make` — present at `/usr/bin/make`
- [✓] `git` — present
- [✓] `curl` — present
- [✗] `docker` — **MISSING** (Install with `sudo apt-get update && sudo apt-get install -y docker.io` to compile and push images)
- [✗] **GKE Cluster Connectivity** — **MISSING** (We are currently unauthorized to list cluster nodes on the target local cluster; you must authenticate to a real GKE cluster using `gcloud container clusters get-credentials`)

---

## Preconditions

1. **GKE Node Pool VM nested virtualization enabled**:
   To run standard KVM inside guest containers, GKE node pools must use GCE VM types that support virtualization (e.g., `n2-standard-4` or similar) with nested virtualization explicitly enabled in the node config.
2. **Host-level Setup (`ublk_drv` & Sysctl)**:
   The `ublk_drv` kernel module and optimal sysctl limits must be applied to all GKE worker nodes. You can run this on each node via GKE node-initialization daemonsets, startup scripts, or by manually SSHing and executing:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/kvcache-ai/AgentENV/main/scripts/docker-setup.sh | sudo bash
   ```
3. **Shared Storage**:
   GCP Cloud Filestore or a shared POSIXFS/OSS bucket (like Google Cloud Storage) must be configured to allow cluster-wide snapshot persistence and exchange.

---

## Steps

### 1. Configure GCP Project Environment
Define your GCP project, region, and GKE cluster variables. *(Do not hardcode these in files — write them dynamically in your terminal environment)*:
```bash
export PROJECT_ID="barni-cnrm-20260529"
export REGION="us-central1"
export GKE_CLUSTER="agentenv-cluster"
export REPO_NAME="agentenv-registry"

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

# Build all three images
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
Execute the helper script to render, bootstrap the `AENV_API_KEY` secret, and apply the configuration:
```bash
# Optionally set a custom sandbox proxy domain
export SANDBOX_PROXY_DOMAINS="sandbox.yourdomain.com"

# Apply manifests to the default namespace (agentenv-system)
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
- `agentenv-scheduler-*` — 1/1 Running
- `agentenv-node-*` — Running on every worker node

### 2. Extract the Generated API Key
Retrieve the cryptographically secure API key generated during deployment from the Kubernetes secret:
```bash
export AENV_API_KEY=$(kubectl -n agentenv-system get secret agentenv-auth \
  -o go-template='{{index .data "AENV_API_KEY" | base64decode}}')
echo "API Key: ${AENV_API_KEY}"
```

### 3. Verify Health and Node Discovery via Gateway Ingress
Query the gateway service to confirm successful registration of all worker nodes:
```bash
# Get gateway ClusterIP or external IP if exposed
export GATEWAY_IP=$(kubectl get svc agentenv-gateway -n agentenv-system -o jsonpath='{.spec.clusterIP}')

# Health check
curl -fsS http://${GATEWAY_IP}:8000/health

# Registered nodes
curl -fsS -H "X-API-Key: ${AENV_API_KEY}" http://${GATEWAY_IP}:8000/nodes
```
**Expected response:** A JSON payload showing active node daemon statuses matching your GKE worker node names.

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
