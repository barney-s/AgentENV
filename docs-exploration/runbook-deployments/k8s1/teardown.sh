#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Source resolved parameters
source "${SCRIPT_DIR}/params.env"

cd "${REPO_ROOT}"

echo "=== Teardown: Deleting AgentENV Kubernetes Resources ==="
export K8S_NAMESPACE="${K8S_NAMESPACE}"
make k8s-delete || true

echo "=== Teardown: Deleting Node Initializer DaemonSet ==="
kubectl delete daemonset agentenv-node-initializer -n kube-system --ignore-not-found || true

echo "=== Teardown: Deleting Artifact Registry Repository ==="
gcloud artifacts repositories delete "${REPO_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --quiet || true

echo "=== Teardown: Deleting GKE Cluster ==="
gcloud container clusters delete "${GKE_CLUSTER}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --quiet || true

echo "=== Teardown: Deleting Snapshot GCS Bucket ==="
gsutil rm -r "gs://${GCS_BUCKET}" || true

echo "=== Teardown: Restoring Repository Manifests ==="
git checkout deploy/k8s/base/kustomization.yaml 2>/dev/null || true

echo "=== Teardown Complete ==="
