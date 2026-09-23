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

## 5. Automated GKE Node Provisioning & Preparation
- **Code Reference**: `scripts/docker-setup.sh`, `deploy/k8s/base/agentenv-daemonset.yaml`
- **Ambiguity**: Running standard GKE Container-Optimized OS (COS) makes loading external kernel modules like `ublk_drv` or altering host sysctl parameters difficult, as the OS is read-only.
- **Question**: Is there an official node initializer image or customized GKE Node Template configuration provided to automate the setup of KVM and `ublk_drv`? Or does AgentENV assume Ubuntu-based GKE worker nodes where kernel module addition is straightforward?

## 6. Privileged Node DaemonSet & Multi-Tenant Security
- **Code Reference**: `deploy/k8s/base/agentenv-daemonset.yaml`
- **Ambiguity**: The `agentenv-node` DaemonSet pod is configured with `privileged: true` and shares the host PID and network namespaces to configure interfaces and mount ublk channels.
- **Question**: What container security practices (e.g., AppArmor, Seccomp, or SELinux policies) are recommended to prevent a compromised runtime node pod from escalating permissions on the host? How is guest-to-host isolation guaranteed if the host directory `/var/lib/aenv` is directly mounted across pods?
