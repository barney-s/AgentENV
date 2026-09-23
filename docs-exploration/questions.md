# Open Questions & Ambiguities

During exploration of the AgentENV codebase, a few architectural nuances and operation specifics remain ambiguous in the code:

---

## 1. Physical Virtualization Mode (PVM) Feasibility
- **Code Reference**: `src/virtualization.rs`, `src/setup/kvm.rs`
- **Ambiguity**: PVM mode requires loading a host kernel module called `kvm_pvm`, which is not present in mainstream Linux kernel releases. 
- **Question**: Is there a specific patchset, custom kernel, or repository that operators must use to build the `kvm_pvm` host module? Additionally, are there detailed performance profiles showing the overhead difference between KVM and PVM under high density?

## 2. OverlayBD Eviction Policies in Large-Scale Production
- **Code Reference**: `src/snapshot/artifact_cache.rs`, `src/cfg.rs`
- **Ambiguity**: In the technical reports, AgentENV handles 1.5 million images by acting as a bounded cache and evicting cold data.
- **Question**: What specific cache eviction algorithm is used to clean up cold layers (e.g., Least Recently Used - LRU)? Is this background garbage collection handled autonomously within the server process, or is it triggered by external crons/orchestrators?

## 3. Data-Plane Proxying Security & Token Enforcement
- **Code Reference**: `services/gateway/`, `src/api/proxy.rs`
- **Ambiguity**: The gateway is described as not authenticating data-plane proxy traffic, delegating this to the runtime node's sandbox policies.
- **Question**: What is the performance overhead on the runtime node when validating token assertions (like `trafficAccessToken` or `X-Access-Token`) during high-frequency API calls or WebSocket streaming? Is there any firewall-level (iptables or eBPF) validation planned for public ingress to prevent DDoS from reaching the guest microVM?

## 4. P2P (Iroh) Topology & Rack-Awareness
- **Code Reference**: `src/p2p/`
- **Ambiguity**: The snapshot manager utilizes Iroh for peer-to-peer snapshot replication.
- **Question**: When replicating large memory/filesystem layers across hundreds of nodes, is there support for topology or rack-awareness? Without it, high-throughput peer transfers might saturate core switches during massive synchronized parallel restarts.
