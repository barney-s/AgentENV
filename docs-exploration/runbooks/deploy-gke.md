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
- **Compute Admin (`roles/compute.admin`)**:
  - `compute.instances.create` / `compute.networks.use` — to provision GCE VM instances and configure nested virtualization.
- **Artifact Registry Administrator (`roles/artifactregistry.admin`)**:
  - `artifactregistry.repositories.create` / `artifactregistry.repositories.write` — to create registry repositories and push AgentENV docker images.
- **Service Account User (`roles/iam.serviceAccountUser`)**:
  - To assign and use the default Compute Engine service account during GKE cluster creation.

### Feasibility Checklist (Current Environment)
- [✓] `gcloud` — present
- [✓] `kubectl` — present (with Kustomize support)
- [✓] `make` — present
- [✓] `git` — present
- [✓] `curl` — present
- [✗] `docker` — **MISSING** (Install with `sudo apt-get update && sudo apt-get install -y docker.io` to compile and push images)
- [✗] **GKE Cluster Connectivity** — **MISSING** (Retrieve credentials via `gcloud container clusters get-credentials`)

---

## Preconditions

1. **Ubuntu GKE Node Image**: GKE node pools must use Ubuntu (`ubuntu_containerd`) as their OS image, because Google Container-Optimized OS (COS) has a read-only root filesystem and restricts loading kernel modules (like `ublk_drv`) and altering host sysctl parameters.
2. **GKE Node Pool Nested Virtualization**: GCE VM types supporting nested virtualization (e.g., `n2-standard-4` or similar Intel-based machines) must be utilized, with nested virtualization explicitly enabled in the node pool configuration.
3. **Host-level Setup (`ublk_drv` & Sysctl)**:
   The `ublk_drv` kernel module and optimal sysctl limits must be applied to all GKE worker nodes. Run this on each node via node-initialization daemonsets, startup scripts, or by manually SSHing and executing:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/kvcache-ai/AgentENV/main/scripts/docker-setup.sh | sudo bash
   ```
4. **Shared Storage & P2P Reachability**:
   A shared POSIXFS (like Cloud Filestore) or Object Storage Service (OSS, like Cloud Storage) must be configured to persist and exchange sandbox snapshot layers, and worker nodes must be able to communicate Pod-to-Pod via P2P listen addresses.

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
echo "Zone: ${ZONE}"
echo "GKE Cluster: ${GKE_CLUSTER}"
echo "Repo Name: ${REPO_NAME}"

gcloud config set project "${PROJECT_ID}"
gcloud config set compute/region "${REGION}"
gcloud config set compute/zone "${ZONE}"
```

### 2. Create GKE Cluster with Nested Virtualization and Ubuntu Node Image
Provision a GKE Standard cluster that satisfies all hardware-level and OS-level virtualization constraints.
```bash
gcloud container clusters create "${GKE_CLUSTER}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --machine-type="n2-standard-4" \
  --image-type="UBUNTU_CONTAINERD" \
  --enable-nested-virtualization \
  --num-nodes=3

# Retrieve credentials to authenticate kubectl
gcloud container clusters get-credentials "${GKE_CLUSTER}" --zone="${ZONE}"
```

### 3. Initialize Host Worker Nodes (ublk_drv & Sysctl)
Choose one of the two following options to configure `ublk_drv` and tune kernel parameters on all GKE worker nodes:

#### Option A: Automated via Node-Initializer DaemonSet (Recommended)
Deploy a transient node-initializer DaemonSet using `nsenter` to load modules and tune sysctl on all worker nodes:
```yaml
# Save as node-initializer.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: agentenv-node-initializer
  namespace: kube-system
  labels:
    app: agentenv-node-initializer
spec:
  selector:
    matchLabels:
      app: agentenv-node-initializer
  template:
    metadata:
      labels:
        app: agentenv-node-initializer
    spec:
      hostPID: true
      hostNetwork: true
      initContainers:
        - name: host-setup
          image: ubuntu:latest
          securityContext:
            privileged: true
          command:
            - nsenter
            - --target
            - "1"
            - --mount
            - --uts
            - --ipc
            - --net
            - --pid
            - --
            - bash
            - -c
            - |
              curl -fsSL https://raw.githubusercontent.com/kvcache-ai/AgentENV/main/scripts/docker-setup.sh | bash
          volumeMounts:
            - name: host-root
              mountPath: /host
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
      volumes:
        - name: host-root
          hostPath:
            path: /
```
```bash
kubectl apply -f node-initializer.yaml
```

#### Option B: Manual via SSH Loop
Loop through GKE worker nodes and apply the setup script directly:
```bash
export NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')

for NODE in ${NODES}; do
  echo "Setting up node ${NODE}..."
  gcloud compute ssh --zone="${ZONE}" "${NODE}" -- \
    "curl -fsSL https://raw.githubusercontent.com/kvcache-ai/AgentENV/main/scripts/docker-setup.sh | sudo bash"
done
```

### 4. Create Artifact Registry and Configure Docker Authentication
Create an Artifact Registry repository to host the AgentENV container images:
```bash
gcloud artifact repositories create "${REPO_NAME}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="AgentENV Docker Images"

gcloud auth configure-docker "${REGION}-docker.pkg.dev"
```

### 5. Configure Shared Storage & P2P Reachability
Before deploying AgentENV, configure `deploy/k8s/base/config/agentenv.toml` to support cluster-wide snapshot sharing and P2P communication:

#### Step 5a: Configure Snapshot Repository Storage Backend (Choose POSIXFS or OSS)
- **Option 1: Google Cloud Storage (OSS S3-Compatible)**
  Create a GCS bucket and generate HMAC credentials for the OSS backend config:
  ```bash
  gsutil mb -l "${REGION}" "gs://${PROJECT_ID}-agentenv-snapshots"
  ```
  Edit `deploy/k8s/base/config/agentenv.toml`:
  ```toml
  [snapshot]
  repository_backend = "oss"
  p2p_enabled = true

  [backend.oss]
  endpoint = "https://storage.googleapis.com"
  bucket = "YOUR_GCS_BUCKET_NAME"
  access_key_id = "YOUR_HMAC_ACCESS_KEY_ID"
  access_key_secret = "YOUR_HMAC_ACCESS_KEY_SECRET"
  ```

- **Option 2: Google Cloud Filestore (Shared POSIXFS)**
  Provision a Cloud Filestore instance, mount it on all nodes at `/mnt/shared`, and create a symlink or host path under `/var/lib/aenv/snapshot-store`.
  Edit `deploy/k8s/base/config/agentenv.toml`:
  ```toml
  [snapshot]
  repository_backend = "posix_fs"
  p2p_enabled = true

  [backend.posix_fs]
  snapshot_store = "/var/lib/aenv/snapshot-store"
  ```

#### Step 5b: Configure P2P Reachability (Pod-to-Pod)
Enable the P2P transport and set a fixed listen port:
```toml
[p2p]
enabled = true
listen_addr = "0.0.0.0:50051"
```
*(Ensure GKE Pod IP routing allows internal cluster-wide TCP traffic on port 50051).*

### 6. Build and Push Container Images
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

### 7. Update Kustomize Image References
Configure Kustomize to use the newly pushed GAR image paths:
```bash
# Update Kustomization image paths in-place
sed -i "s#newName: agentenv-gateway#newName: ${K8S_GATEWAY_IMAGE}#" deploy/k8s/base/kustomization.yaml
sed -i "s#newName: agentenv-scheduler#newName: ${K8S_SCHEDULER_IMAGE}#" deploy/k8s/base/kustomization.yaml
sed -i "s#newName: agentenv-runtime#newName: ${K8S_RUNTIME_IMAGE}#" deploy/k8s/base/kustomization.yaml
```

### 8. Apply Manifests to the GKE Cluster
Apply the configuration and bootstrap secrets to the cluster (default namespace: `agentenv-system`):
```bash
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
- `agentenv-scheduler-*` — 1/1 Running (Single replica)
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
*(Optional: Delete the Artifact Registry repository, GCS bucket, and GKE cluster if they are no longer needed)*
```bash
gcloud artifact repositories delete "${REPO_NAME}" --location="${REGION}" --quiet
gcloud container clusters delete "${GKE_CLUSTER}" --zone="${ZONE}" --quiet
gsutil rm -r "gs://${PROJECT_ID}-agentenv-snapshots"
```
