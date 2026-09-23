# AgentENV Code Map

This document outlines the codebase directory structure, specifies the 20 files that matter most, and points out files that are dangerous to modify.

---

## Directory-by-Directory Layout

### 1. `src/` (Core Node Daemon)
- **`src/bin/`**: Execution entry points. `server.rs` is the main daemon, and `aenv-snapshot-image.rs` is for image compression.
- **`src/api/`**: Axum HTTP routing rules and E2B mapping logic. Implementation files are housed in `src/api/impls/` (for images, templates, sandboxes, volumes).
- **`src/orchestrator/`**: The state machine manager. Tracks running microVM lifecycles, and auto-evicts idle sandboxes.
- **`src/sandbox/`**: Backing isolation systems.
  - `sandbox/firecracker/`: Spawns and manages Firecracker OS subprocesses and issues socket commands.
  - `sandbox/network/`: Creates host TAP adapters and configures iptables/firewall limits.
  - `sandbox/ublk/`: Integrates overlaybd layered filesystem with local user-space block devices.
- **`src/snapshot/`**: Code for saving memory and block device layers. Supports multiple storage backends in `src/snapshot/repository/backends/` (POSIX files or Cloud Object Storage / OSS).
- **`src/template/`**: Manages OCI container image conversion into AgentENV microVM-ready templates.
- **`src/p2p/`**: Enables direct, cluster-wide peer-to-peer distribution of snapshot chunks and layers using an embedded `iroh` daemon.

### 2. `storage/` (Custom Virtualization Storage)
- **`storage/overlaybd/`**: Custom Rust crate that maps multi-layered OCI images and disk-delta snapshots into unified virtual block images.
- **`storage/ublk/`**: Low-level Rust wrapper interfacing with the `/dev/ublk-control` driver in the Linux kernel.
- **`storage/ublk-daemon/`**: Implements the user-space I/O loop to service read/write requests from the ublk virtual devices.
- **`storage/uffd-core/`**: Implements `userfaultfd` handling. Intercepts guest memory page faults to pull memory snapshot blocks lazily.

### 3. `crates/` (Workspace Support Libraries)
- **`crates/aenv/`**: Contains the source code of the standalone client CLI executable `aenv`.
- **`crates/linux-cap/`**: Manages granular Linux capability sets so that the runtime can execute without full root privileges.
- **`crates/warm-pool/`**: Generates pre-warmed sandbox pools to cut boot time under heavy load.
- **`crates/observability/`**: Exposes Prometheus metrics and schedules heartbeat reports to the distributed scheduler.

### 4. `services/` (Go Distributed Services)
- **`services/gateway/`**: Distributed entry point that routes client REST and WebSocket requests to the correct host.
- **`services/scheduler/`**: Manages host node rosters and assigns new sandbox requests via customizable strategies.

---

## Top 20 Critical Files

1. **`Cargo.toml`**: The parent workspace manifest mapping all dependencies, optimizer flags, and cargo members.
2. **`src/bin/server.rs`**: Main server bootstrap. Initializes the ublk daemon, template builder, snapshot managers, and starts the API server.
3. **`crates/aenv/src/main.rs`**: The main entrypoint for the `aenv` client CLI commands.
4. **`src/cfg.rs`**: Defines `AppConfig`, containing all server tuning properties and environmental overrides.
5. **`src/orchestrator/service.rs`**: Coordinates sandbox transactions (start, pause, resume, delete). Prevents double-starts and schedules eviction routines.
6. **`src/sandbox/firecracker/sandbox.rs`**: Handles VM-level booting, network binding, and coordinates ublk/overlaybd disk mounts.
7. **`src/sandbox/firecracker/instance.rs`**: Manages the life of the raw `firecracker` process, standard error logging, and Unix socket communication.
8. **`src/sandbox/ublk/device.rs`**: Binds OverlayBD layers to active ublk channels.
9. **`src/sandbox/ublk/overlaybd.rs`**: Merges local raw block layers, generates compression args, and coordinates layer uploads.
10. **`storage/overlaybd/src/lib.rs`**: Core library entrypoint for overlaybd layered block emulation.
11. **`storage/ublk/src/lib.rs`**: Low-level kernel control-loop implementation for ublk queues.
12. **`storage/uffd-core/src/handler.rs`**: Handles lazy-load user-space memory page fault routines.
13. **`src/snapshot/manager.rs`**: Coordinates incremental state capture, publishing, and cache management.
14. **`src/snapshot/repository/backends/mod.rs`**: Abstracted repository resolver (PosixFS vs. Object Storage/S3).
15. **`src/p2p/iroh/transport.rs`**: Integrates Iroh peer-to-peer block exchange for image layer replication.
16. **`src/volume.rs`**: Provisions ext4 virtual disks used for persistent user volume mounts.
17. **`src/template/builder.rs`**: Orchestrates container re-containerization and image extraction via buildkit.
18. **`src/api/server.rs`**: Maps the Axum router, WebSocket handlers, and TCP nodelay socket configurations.
19. **`services/gateway/main.go`**: Reverse proxy router and E2B routing-header resolver.
20. **`services/scheduler/main.go`**: Node heartbeat store and scheduling resolver.

---

## Dangerous Files to Modify

The following files require extreme caution during editing. Minor bugs here can trigger operating system failures, lockup kernel queues, or introduce serious security breaches:

- **`storage/ublk/` & `storage/ublk-daemon/`**: These files talk directly to kernel block layers via io-uring. Queue handling bugs, invalid index references, or memory unsafety here can cause the entire system to freeze, crash the host kernel, or lead to storage corruption.
- **`storage/uffd-core/`**: Uses `userfaultfd` to intercept kernel page faults. Unhandled fault states or deadlocks in this event-loop will freeze the execution threads of guest microVMs, causing unkillable zombie processes.
- **`src/sandbox/firecracker/instance.rs`**: Manages OS-level child processes, Unix domain socket descriptors, and low-level signaling. Resource cleanup leaks or bad socket locks can quickly exhaust KVM descriptors or host memory.
- **`src/privileges.rs`**: Hand-crafts process capability transitions. Any error here can either disable the server completely or accidentally escalate running microVM privileges to root-level scope.
