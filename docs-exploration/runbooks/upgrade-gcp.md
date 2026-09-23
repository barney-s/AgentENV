# Runbook: Upgrade (gcp)

Perform a zero-downtime rolling upgrade of the AgentENV stack on a Google Kubernetes Engine (GKE) cluster in Google Cloud Platform (GCP).

---

## What this needs

Can this run in the pod/sandbox?
No. Upgrading GKE workloads requires GKE cluster access, Artifact Registry permissions, and image build capabilities.

### Required GCP / IAM Permissions
The executing identity requires:
- **Kubernetes Engine Developer (`roles/container.developer`)** or higher:
  - `container.deployments.update` / `container.rollouts.get` — to trigger and monitor rolling restarts.
- **Artifact Registry Writer (`roles/artifactregistry.writer`)**:
  - `artifactregistry.repositories.uploadArtifacts` — to push the updated container images.

### Feasibility Checklist (Current Environment)
- [✓] **IAM Owner Role** — **GRANTED** (The active credentials have `roles/owner` on the GCP project `${PROJECT_ID}`)
- [✓] `gcloud` — present at `/usr/bin/gcloud`
- [✓] `kubectl` — present at `/usr/bin/kubectl`
- [✓] `make` — present at `/usr/bin/make`
- [✓] `git` — present
- [✓] `curl` — present
- [✗] `docker` — **MISSING** (Install with `sudo apt-get update && sudo apt-get install -y docker.io` to compile and push images)
- [✗] **GKE Cluster Connectivity** — **MISSING** (No active GKE clusters found in the target region `${REGION}`; you must create a cluster or retrieve credentials via `gcloud container clusters get-credentials`)

---

## Preconditions

1. A running AgentENV deployment exists in the GKE cluster in the `agentenv-system` namespace.
2. The `agentenv-auth` secret containing the cluster API key must be preserved to prevent client authentication failures.

---

## Steps

### 1. Configure GCP Project and GKE Context
Define environment variables matching your target cluster by sourcing `params.env` (where instance parameters are resolved at plan time from Settings and guidance):
```bash
# Load instance parameters
source params.env

# Confirm environment variables are loaded
echo "Project ID: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "GKE Cluster: ${GKE_CLUSTER}"
echo "Repo Name: ${REPO_NAME}"

gcloud config set project "${PROJECT_ID}"
gcloud container clusters get-credentials "${GKE_CLUSTER}" --region "${REGION}"
```

### 2. Build and Tag New Container Images
To avoid overwriting existing images and ensure clean rollbacks, use the current Git commit SHA as the new tag:
```bash
export REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}"
export TAG=$(git rev-parse --short HEAD)

export K8S_RUNTIME_IMAGE="${REGISTRY}/agentenv-runtime:${TAG}"
export K8S_GATEWAY_IMAGE="${REGISTRY}/agentenv-gateway:${TAG}"
export K8S_SCHEDULER_IMAGE="${REGISTRY}/agentenv-scheduler:${TAG}"

# Re-compile and build container images
make k8s-build
```

### 3. Push Upgraded Images to Artifact Registry
Authenticate Docker and push the newly tagged images:
```bash
gcloud auth configure-docker "${REGION}-docker.pkg.dev"

docker push "${K8S_RUNTIME_IMAGE}"
docker push "${K8S_GATEWAY_IMAGE}"
docker push "${K8S_SCHEDULER_IMAGE}"
```

### 4. Update Manifest Tags
Update the image names and tags in the Kustomization configuration:
```bash
sed -i "s#newName: agentenv-gateway#newName: ${K8S_GATEWAY_IMAGE}#" deploy/k8s/base/kustomization.yaml
sed -i "s#newName: agentenv-scheduler#newName: ${K8S_SCHEDULER_IMAGE}#" deploy/k8s/base/kustomization.yaml
sed -i "s#newName: agentenv-runtime#newName: ${K8S_RUNTIME_IMAGE}#" deploy/k8s/base/kustomization.yaml

sed -i "s#newTag: .*#newTag: ${TAG}#" deploy/k8s/base/kustomization.yaml
```

### 5. Re-apply Configurations and Restart Workloads
Re-apply the configurations to the GKE cluster. The helper script ensures `AENV_API_KEY` is preserved and reads it from the existing Secret:
```bash
# Re-apply the updated manifests
make k8s-apply

# Trigger rolling update and monitor progress
make k8s-redeploy
```
*(Note: `make k8s-redeploy` performs a rolling restart of the gateway deployment, scheduler deployment, and node daemonset sequentially, waiting for each to reach a healthy status. This guarantees a zero-downtime upgrade path.)*

---

## Verify

### 1. Monitor Rolling Restart Progress
Check the rollout status of all three components to ensure they have fully transitioned:
```bash
kubectl rollout status deployment/agentenv-gateway -n agentenv-system
kubectl rollout status deployment/agentenv-scheduler -n agentenv-system
kubectl rollout status daemonset/agentenv-node -n agentenv-system
```

### 2. Confirm Persisted API Credentials
Verify that the previously configured API Key is still active and successfully authenticates:
```bash
# Extract preserved API key
export AENV_API_KEY=$(kubectl -n agentenv-system get secret agentenv-auth \
  -o go-template='{{index .data "AENV_API_KEY" | base64decode}}')

# Extract gateway IP
export GATEWAY_IP=$(kubectl get svc agentenv-gateway -n agentenv-system -o jsonpath='{.spec.clusterIP}')

# Authenticate against updated Gateway
curl -fsS -H "X-API-Key: ${AENV_API_KEY}" http://${GATEWAY_IP}:8000/nodes
```
**Expected response:** A successful HTTP 200 list of registered active nodes, showing that nodes successfully re-registered with the upgraded scheduler and the gateway accepted the persisted key.

---

## Teardown

If the upgrade was successful, no cleanup of active workloads is needed.
If you need to roll back to the previous deployment, revert the image tags in the Kustomize manifests to the previous version and run:
```bash
make k8s-apply
make k8s-redeploy
```
