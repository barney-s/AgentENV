#!/usr/bin/env bash
# Build container images via Cloud Build (due to sandbox container unshare limits), fixed gcloud artifacts command, and robust kustomize image replacements
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Source resolved parameters
source "${SCRIPT_DIR}/params.env"

cd "${REPO_ROOT}"

echo "=== Step 1: Configure GCP Project Environment ==="
echo "Project ID: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "Zone: ${ZONE}"
echo "GKE Cluster: ${GKE_CLUSTER}"
echo "Repo Name: ${REPO_NAME}"

gcloud config set project "${PROJECT_ID}"
gcloud config set compute/region "${REGION}"
gcloud config set compute/zone "${ZONE}"

echo "=== Step 2: Create GKE Cluster with Nested Virtualization and Ubuntu Node Image ==="
if ! gcloud container clusters describe "${GKE_CLUSTER}" --zone="${ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud container clusters create "${GKE_CLUSTER}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="n2-standard-4" \
    --image-type="UBUNTU_CONTAINERD" \
    --enable-nested-virtualization \
    --num-nodes=3 \
    --labels="repo-agent-instance=${RESOURCE_PREFIX}"
else
  echo "GKE cluster ${GKE_CLUSTER} already exists."
fi

# Retrieve credentials to authenticate kubectl
gcloud container clusters get-credentials "${GKE_CLUSTER}" --zone="${ZONE}" --project="${PROJECT_ID}"

echo "=== Step 3: Initialize Host Worker Nodes (ublk_drv & Sysctl) ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: agentenv-node-initializer
  namespace: kube-system
  labels:
    app: agentenv-node-initializer
    repo-agent-instance: agentenv-k8s1
spec:
  selector:
    matchLabels:
      app: agentenv-node-initializer
  template:
    metadata:
      labels:
        app: agentenv-node-initializer
        repo-agent-instance: agentenv-k8s1
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
EOF

echo "Waiting for node initializer DaemonSet to complete rollout..."
kubectl rollout status daemonset/agentenv-node-initializer -n kube-system --timeout=180s

echo "=== Step 4: Create Artifact Registry and Configure Docker Authentication ==="
if ! gcloud artifacts repositories describe "${REPO_NAME}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud artifacts repositories create "${REPO_NAME}" \
    --project="${PROJECT_ID}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="AgentENV Docker Images" \
    --labels="repo-agent-instance=${RESOURCE_PREFIX}"
else
  echo "Artifact repository ${REPO_NAME} already exists."
fi

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo "=== Step 5: Configure Shared Storage (GCS Bucket) ==="
if ! gsutil ls -b "gs://${GCS_BUCKET}" &>/dev/null; then
  gsutil mb -p "${PROJECT_ID}" -l "${REGION}" "gs://${GCS_BUCKET}" || true
fi

echo "=== Step 6: Build and Push Container Images via Cloud Build ==="
export REGISTRY="${REGISTRY}"
export K8S_RUNTIME_IMAGE="${K8S_RUNTIME_IMAGE}"
export K8S_GATEWAY_IMAGE="${K8S_GATEWAY_IMAGE}"
export K8S_SCHEDULER_IMAGE="${K8S_SCHEDULER_IMAGE}"

# Check if all images already exist in registry to avoid redundant builds
if ! gcloud artifacts docker images describe "${K8S_RUNTIME_IMAGE}" &>/dev/null || \
   ! gcloud artifacts docker images describe "${K8S_GATEWAY_IMAGE}" &>/dev/null || \
   ! gcloud artifacts docker images describe "${K8S_SCHEDULER_IMAGE}" &>/dev/null; then
  echo "Submitting Cloud Build job for AgentENV container images..."
  gcloud builds submit \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --config="${SCRIPT_DIR}/cloudbuild.yaml" \
    --substitutions="_K8S_GATEWAY_IMAGE=${K8S_GATEWAY_IMAGE},_K8S_SCHEDULER_IMAGE=${K8S_SCHEDULER_IMAGE},_K8S_RUNTIME_IMAGE=${K8S_RUNTIME_IMAGE}" \
    "${REPO_ROOT}"
else
  echo "All container images already exist in Artifact Registry."
fi

echo "=== Step 7: Update Kustomize Image References ==="
python3 -c '
import re

with open("deploy/k8s/base/kustomization.yaml", "r") as f:
    content = f.read()

images = {
    "agentenv-gateway": "'"${K8S_GATEWAY_IMAGE}"'",
    "agentenv-scheduler": "'"${K8S_SCHEDULER_IMAGE}"'",
    "agentenv-runtime": "'"${K8S_RUNTIME_IMAGE}"'"
}

for name, full_image in images.items():
    if ":" in full_image:
        image_name, image_tag = full_image.rsplit(":", 1)
    else:
        image_name, image_tag = full_image, "latest"
    pattern = rf"(- name:\s*{name}\s*\n\s*newName:\s*)\S+(\s*\n\s*newTag:\s*)\S+"
    content = re.sub(pattern, rf"\g<1>{image_name}\g<2>{image_tag}", content)

with open("deploy/k8s/base/kustomization.yaml", "w") as f:
    f.write(content)
'

echo "=== Step 8: Apply Manifests to the GKE Cluster ==="
export K8S_NAMESPACE="${K8S_NAMESPACE}"
make k8s-apply

echo "=== Deployment Finished ==="
echo "Workloads deployed to namespace: ${K8S_NAMESPACE}"
echo "Verify status: kubectl get pods -n ${K8S_NAMESPACE}"
