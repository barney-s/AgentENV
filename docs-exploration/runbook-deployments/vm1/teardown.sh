#!/bin/bash
set -euo pipefail

# Determine script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source params.env
source "${SCRIPT_DIR}/params.env"

echo "===================================================="
echo "Tearing Down AgentENV VM Instance"
echo "Project:  ${PROJECT_ID}"
echo "Zone:     ${ZONE}"
echo "VM Name:  ${VM_NAME}"
echo "===================================================="

# Set GCP config
echo "Configuring gcloud project and zone..."
gcloud config set project "${PROJECT_ID}"
gcloud config set compute/zone "${ZONE}"

# Since VM deletion fully terminates the instance and deletes all disk storage,
# we directly delete the VM.
echo "Deleting GCE VM instance ${VM_NAME}..."
gcloud compute instances delete "${VM_NAME}" --zone="${ZONE}" --quiet

echo "===================================================="
echo "Teardown completed successfully!"
echo "===================================================="
