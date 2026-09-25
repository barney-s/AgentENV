# Open Questions & Ambiguities

During exploration of the AgentENV codebase, we have researched and resolved several of the key architectural nuances, ambiguities, and operation specifics. Below is the updated record of our findings:

---

## 1. Physical Virtualization Mode (PVM) Feasibility
- **Code Reference**: `src/virtualization.rs`, `src/setup/kvm.rs`
- **Resolution**: PVM mode requires an `x86_64` architecture and is dependent on the custom `kvm_pvm` kernel module being loaded on the host (the check verifies the existence of `/sys/module/kvm_pvm`).
- **Mutual Exclusion**: KVM and PVM modes are strictly mutually exclusive:
  - Standard KVM mode will fail to start if the `kvm_pvm` module is loaded.
  - PVM mode will fail to validate and start if the `kvm_pvm` module is not loaded.
- **Open Questions**: There is still no upstream or mainstream Linux kernel patchset included in this repo for `kvm_pvm`. Operators must use a custom-built kernel/module, and precise performance overhead comparisons between KVM and PVM under high density remain undocumented.

## 2. OverlayBD Eviction Policies in Large-Scale Production
- **Code Reference**: `src/snapshot/artifact_cache.rs`, `src/cfg.rs`
- **Resolution**: Bounded cache eviction is implemented in the local daemon via `LocalArtifactCache`. 
- **Algorithm & Mechanism**:
  - Uses a **Least Recently Used (LRU)** eviction algorithm.
  - The default cache size is 10 GB (configurable via `max_size_gb` under snapshot settings).
  - When the cache total size exceeds the configured limit, a background eviction routine (`evict_lru`) is spawned asynchronously using a Tokio task.
  - It evicts unpinned files (where `ref_count == 0`) down to an 80% target ratio (`EVICTION_TARGET_RATIO = 0.8`).
  - Active sandboxes hold a reference-counted lease (`ref_count > 0`), pinning associated artifact files and guaranteeing they will not be evicted during runtime execution.

## 3. Data-Plane Proxying Security & Token Enforcement
- **Code Reference**: `services/gateway/`, `src/api/impls/auth.rs`, `src/api/proxy.rs`
- **Resolution**: In-flight token verification is handled efficiently at the local node daemon level.
- **Middleware Design**:
  - The Axum middleware (`require_auth` in `src/api/impls/auth.rs`) intercepting requests enforces token rules.
  - For standard API requests, it checks the `x-api-key` header.
  - For proxy requests targeting `envd` ports, it checks `x-access-token` via `validate_envd_access_token` (if sandbox security is active).
  - For custom application ports, if public traffic is disabled, it verifies `e2b-traffic-access-token` using `validate_traffic_access_token`.
- **Open Questions**: These checks perform lookup matching against local/orchestrator-cached metadata in memory. No kernel-level or firewall-level (like eBPF or iptables-based) token validations are implemented on the public ingress to filter high-volume DDoS traffic before it reaches the guest microVM.

## 4. P2P (Iroh) Topology & Rack-Awareness
- **Code Reference**: `src/p2p/`, `src/p2p/iroh/transport.rs`
- **Resolution**: Replicating snapshot files and OCI layers is executed via embedded `iroh` and `iroh-blobs`.
- **Topology Limit**:
  - No physical network topology, rack-awareness, or location-aware replication is implemented in the P2P layer.
  - Nodes discover peers using `P2pPeerDiscovery` and communicate directly over Iroh endpoints.
- **Open Questions**: In massive, synchronized parallel rollouts, there is a risk of core network switch saturation, as the P2P transport does not restrict cross-rack communication.

## 5. Automated GKE Node Provisioning & Preparation
- **Code Reference**: `scripts/docker-setup.sh`, `deploy/k8s/base/agentenv-daemonset.yaml`
- **Resolution**: GKE worker nodes must use Ubuntu (`ubuntu_containerd`) as their OS image, because Google Container-Optimized OS (COS) has a read-only root filesystem and restricts loading kernel modules and altering sysctl parameters. The initialization is automated via a node-initializer DaemonSet using `nsenter` to run `scripts/docker-setup.sh` on the host, or can be run manually via an SSH loop.

## 6. Privileged Node DaemonSet & Multi-Tenant Security
- **Code Reference**: `deploy/k8s/base/agentenv-daemonset.yaml`
- **Ambiguity**: The `agentenv-node` DaemonSet pod is configured with `privileged: true` and shares the host PID and network namespaces to configure interfaces and mount ublk channels.
- **Question**: What container security practices (e.g., AppArmor, Seccomp, or SELinux policies) are recommended to prevent a compromised runtime node pod from escalating permissions on the host? How is guest-to-host isolation guaranteed if the host directory `/var/lib/aenv` is directly mounted across pods?
