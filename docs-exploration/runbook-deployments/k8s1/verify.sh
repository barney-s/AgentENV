#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/params.env"

echo "=== 1. Workload Pod Statuses ==="
kubectl get pods -n "${K8S_NAMESPACE}" -o wide

echo "=== 2. Extract Generated API Key ==="
AENV_API_KEY=$(kubectl -n "${K8S_NAMESPACE}" get secret agentenv-auth -o go-template='{{index .data "AENV_API_KEY" | base64decode}}')
echo "API Key loaded: ${AENV_API_KEY:0:10}..."

echo "=== 3. Gateway Ingress Probing via Port Forward ==="
kubectl port-forward svc/agentenv-gateway 8000:8080 -n "${K8S_NAMESPACE}" &
PF_PID=$!
trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT

sleep 3

echo "--- Probing /health ---"
curl -fsS http://127.0.0.1:8000/health
echo ""

echo "--- Probing /nodes with API Key ---"
curl -fsS -H "X-API-Key: ${AENV_API_KEY}" http://127.0.0.1:8000/nodes
echo ""

echo "=== Verification Succeeded ==="
