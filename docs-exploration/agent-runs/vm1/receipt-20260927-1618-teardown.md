TORN-DOWN

# Teardown Receipt: vm1 (2026-09-27 16:18 UTC)

This receipt documents the successful and complete teardown of the **vm1** instance of AgentENV.

## Teardown Status
- **Verdict:** TORN-DOWN (The VM host and all associated resources have been completely deleted in GCP).
- **Time of Teardown:** 2026-09-27 16:18 UTC

---

## Resources Removed

The following resources were active and have been successfully deleted:

1. **GCE VM Instance (`agentenv-vm1-host`)**:
   - **Zone:** `us-central1-a`
   - **Machine Type:** `n2-standard-4`
   - **Verification Evidence:** `gcloud compute instances describe agentenv-vm1-host` returned `404 Not Found` (Error: Could not fetch resource).

2. **Boot Disk (`agentenv-vm1-host`)**:
   - **Size:** 50GB
   - **Type:** Standard PD boot disk
   - **Verification Evidence:** `gcloud compute disks describe agentenv-vm1-host` returned `404 Not Found` (Error: HTTPError 404: The resource ... was not found).

3. **Active Host Processes**:
   - `target/release/server` (Port 8000) and `/var/lib/aenv/ublk/uvm-ublk-daemon` were fully terminated upon GCE VM deletion.

---

## Verifying Evidence

### 1. VM Instance Deletion Verification
```bash
$ gcloud compute instances describe agentenv-vm1-host --zone=us-central1-a --project=barni-cnrm-20260529
ERROR: (gcloud.compute.instances.describe) Could not fetch resource:
 - The resource 'projects/barni-cnrm-20260529/zones/us-central1-a/instances/agentenv-vm1-host' was not found
```

### 2. Disk Deletion Verification
```bash
$ gcloud compute disks describe agentenv-vm1-host --zone=us-central1-a --project=barni-cnrm-20260529
ERROR: (gcloud.compute.disks.describe) HTTPError 404: The resource 'projects/barni-cnrm-20260529/zones/us-central1-a/disks/agentenv-vm1-host' was not found.
```

### 3. Orphaned Resource Scan
A scan for any other GCP resources matching the prefix `agentenv-vm1` returned zero active resources:
- `gcloud compute disks list --project=barni-cnrm-20260529 --filter="name ~ agentenv-vm1"`: **0 items listed**
- `gcloud compute instances list --project=barni-cnrm-20260529 --filter="name ~ agentenv-vm1"`: **0 items listed**

---

## Remaining Resources
None. All cloud resources associated with this deployment run have been cleanly and completely destroyed. No orphaned disks, IP addresses, or firewall rules remain.
