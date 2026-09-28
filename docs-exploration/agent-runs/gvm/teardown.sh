#!/usr/bin/env bash
# Teardown AgentENV GCP infrastructure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/params.env"

echo "=== Tearing down AgentENV GCP Resources ==="

if gcloud compute instances describe "${INSTANCE_NAME}" --project="${PROJECT}" --zone="${ZONE}" >/dev/null 2>&1; then
  echo "Deleting Compute Engine instance ${INSTANCE_NAME} in zone ${ZONE}..."
  gcloud compute instances delete "${INSTANCE_NAME}" \
    --project="${PROJECT}" \
    --zone="${ZONE}" \
    --quiet
else
  echo "Compute instance ${INSTANCE_NAME} does not exist."
fi

if gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME}" --project="${PROJECT}" >/dev/null 2>&1; then
  echo "Deleting firewall rule ${FIREWALL_RULE_NAME}..."
  gcloud compute firewall-rules delete "${FIREWALL_RULE_NAME}" \
    --project="${PROJECT}" \
    --quiet
else
  echo "Firewall rule ${FIREWALL_RULE_NAME} does not exist."
fi

echo "Teardown complete."
