# AgentENV Overview

**AgentENV (AENV)** is a platform designed to run LLM/AI agent sandboxes and environments at massive scale. It powers agentic Reinforcement Learning (RL) training for Moonshot AI's **Kimi K3**, scaling to manage **1.5 million images** in production across large-scale clusters.

## Why AgentENV Exists

AI agents need highly isolated, secure environments (sandboxes) to execute untrusted code and interact with various system dependencies. Traditional containerization (like Docker or Kubernetes pods) lacks the sub-second sleep/resume, native memory/filesystem snapshotting, and low-overhead microVM-level isolation required for high-throughput RL training.

While Firecracker microVMs provide secure, hardware-level isolation, standard orchestration tooling cannot handle the extreme density, immediate boot latency, and massive image catalog requirements. AgentENV solves this by combining a custom Rust-based microVM orchestrator, a peer-to-peer (P2P) distribution layer, and a highly optimized storage engine (`overlaybd` and `ublk`).

---

## Core Value Proposition

### 1. High Performance & Extreme Density
- **Memory Overcommit**: Achieves a **9.6x memory overcommit ratio** in production using memory ballooning and host page cache sharing, returning reclaimable guest memory back to the host.
- **Shared Page Cache**: Storage (`overlaybd`) and memory-snapshot data share the host page cache, maximizing memory efficiency as microVMs run and diverge over time.

### 2. Sub-Second Lifecycle Operations
- **Blazing-Fast Startup**: Snapshot-backed sandboxes boot or resume in **under 50 ms**.
- **Low-Latency Pause/Capture**: Sandboxes pause in under 100 ms, releasing CPU and memory resources when idle, and resume instantly when new workloads arrive.
- **Incremental Snapshots**: Filesystem and memory state are snapshotted incrementally in **under 100 ms**, even under heavy disk writing.

### 3. Native Snapshot & Fork Support
- **Parallel Exploration**: A running sandbox can be cloned or forked into multiple independent, parallel sandboxes. This is crucial for tree-search or parallel rollout algorithms in reinforcement learning.
- **Durable Snapshots**: Snapshots are backed up incrementally to S3-compatible object storage (OSS) or shared filesystems (PosixFS) to ensure data durability.

### 4. Bounded Local Storage Caching
- **No Host Pre-warming**: Standard Docker-based workflows require pulling and unpacking massive images on every host before launch. AgentENV loads diverse OCI-compatible images dynamically on-demand.
- **Bounded Local Disk Cache**: Local disk space acts as a bounded cache. It retains hot data and evicts cold data. This allows the cluster-wide image and snapshot footprint to exceed local disk limits by multiple orders of magnitude without cluster-wide storage exhaustion.

### 5. Seamless API & E2B Compatibility
- **E2B SDK Compatible**: AgentENV exposes an E2B-compatible REST API. Developers can point the official E2B Python or TypeScript SDKs directly to an AgentENV gateway with no code modifications.
- **Interactive Shell & File Transfer**: Out-of-the-box support for interactive terminal connections (`aenv start`, `aenv cn`), command execution (`aenv exec`), and file uploads/downloads.

---

## Target Audience

AgentENV is built for:
- **ML / AI Research Teams** running massive RL training workloads that need to spawn, fork, and pause hundreds of thousands of parallel microVMs.
- **AI Agent Platform Operators** who require secure, multi-tenant sandboxes with high density and low idle costs.
- **Enterprise Engineering Teams** looking for an open-source, high-performance, and cluster-capable alternative to commercial sandbox solutions like E2B.
