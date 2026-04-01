# Research: Local VM for Isolated Agent Environment

## Topic

Evaluate local VM approaches on macOS (Apple Silicon) as an alternative to the Docker-based isolation in `attempt-001-docker/`, with emphasis on live code sharing, disposability, and stronger isolation guarantees.

## Context

The Docker-based approach (`attempt-001-docker/`) works but has fundamental architectural weaknesses identified in its own audit (`issues-and-tradeoffs.md`):

- The firewall is self-controlled: the container holds `NET_ADMIN` and can flush its own iptables rules.
- The container runs as root, making the `chmod -R a-w .git/hooks` protection ineffective.
- DNS port 53 is fully open, enabling DNS exfiltration.
- The container shares the host kernel, so isolation depends on namespace boundaries rather than a hypervisor.

A VM provides a fundamentally stronger boundary: the guest has its own kernel, and network/firewall policy can be enforced at the host level where the guest process cannot reach it.

The user wants:
- Code shared from the host, live-updated, viewable in host IDE/tools
- A disposable VM that is simple to recreate
- Simplicity of operation comparable to the Docker approach

---

## Findings

### 1. VM Tool Options on macOS Apple Silicon

Six tools were evaluated. The two strongest candidates for this use case are **Lima** and **Tart**.

#### Lima (Recommended Starting Point)

- **License:** Open source (Apache 2.0)
- **Backend:** QEMU or Apple Virtualization.framework (`vmType: vz`). VZ is preferred on Apple Silicon for near-native performance.
- **Cloud-init:** Native support. VM configuration is a single YAML file covering resources, mounts, networking, and provisioning scripts. This file can be version-controlled.
- **CLI:** `limactl create|start|stop|delete|shell|clone|list|snapshot`. Fully scriptable (`--tty=false` disables interactive prompts).
- **Guest OS:** Any Linux distribution with cloud images available.
- **Cloning:** `limactl clone` uses APFS `clonefile(2)` for near-instant, space-efficient copy-on-write clones of a base VM.

#### Tart (Strong Alternative)

- **License:** Open source (Fair Source)
- **Backend:** Apple Virtualization.framework only (no QEMU fallback).
- **Images as OCI artifacts:** VM images can be pushed/pulled from container registries (ghcr.io, Docker Hub, etc.).
- **CLI:** `tart create|clone|run|stop|delete|set|list|ip|pull|push`.
- **No cloud-init:** Provisioning uses Packer or manual setup, not cloud-init.
- **Best for:** CI/CD and pre-built golden images. Less flexible for ad-hoc provisioning.

#### Others Considered but Not Recommended

| Tool       | Why Not                                                                                          |
|------------|--------------------------------------------------------------------------------------------------|
| OrbStack   | Shared kernel (not true VMs) -- weaker isolation than a real hypervisor boundary. Commercial.    |
| UTM/QEMU   | GUI-oriented, poor CLI automation, no cloud-init, manual VM creation.                            |
| Multipass  | SSHFS-only on macOS (slow), Ubuntu-only, no VirtioFS support on macOS.                           |
| Colima     | Lima wrapper designed for Docker workflows, not general-purpose VM management.                   |

---

### 2. Filesystem Sharing

This is the critical requirement: host code must be live-editable and visible from host tools.

#### VirtioFS (Apple Virtualization.framework)

- **Performance:** ~70-90% of native filesystem speed. Acceptable for IDE use.
- **Requirement:** `vmType: vz` and macOS 13+ (Ventura).
- **Bidirectional:** Host writes are immediately visible in the guest and vice versa.
- **Lima config:**
  ```yaml
  vmType: vz
  mounts:
    - location: "~/src/my-project"
      writable: true
      mountType: "virtiofs"
  ```

#### Protocol Comparison

| Protocol | Relative Speed    | Available On                        | Notes                                            |
|----------|-------------------|-------------------------------------|--------------------------------------------------|
| VirtioFS | ~70-90% native    | Lima(VZ), Tart, UTM(AVF), Colima    | Best option; requires macOS 13+, VZ mode         |
| 9P       | ~10-30% native    | Lima(QEMU), Colima(QEMU)            | Too slow for dev work (`git status` ~30s)        |
| SSHFS    | ~5-20% native     | Lima, Multipass                     | SSH overhead; unreliable under concurrent I/O    |
| NFS      | ~40-60% native    | Manual setup only                   | No tool has built-in NFS support                 |

#### inotify / File System Notifications

**No tool provides fully reliable inotify across the host-guest boundary today.**

- Lima has experimental `mountInotify: true` (v0.21.0+), but 9P misses nested events and host deletions aren't forwarded.
- OrbStack has active bugs with fsnotify CREATE events on macOS 15.
- Tart and UTM have no documented inotify support over VirtioFS.

**Practical implication:** File watchers (Go test runners, webpack, etc.) should run inside the VM on the mounted path, or use polling-based watching. Host IDE tools reading files directly (not relying on filesystem events) will work fine since VirtioFS reads are immediate.

---

### 3. Network Isolation

A VM provides fundamentally better network isolation than a container because the guest has its own kernel -- firewall rules inside the VM are enforced by a separate kernel that the guest process cannot escape.

#### Lima Networking Modes

| Mode                  | Host-Visible Interface | pf Filterable | Notes                                                      |
|-----------------------|------------------------|---------------|------------------------------------------------------------|
| slirp (default)       | No                     | No            | Traffic exits via Lima host-agent process                  |
| user-v2 (gvproxy)     | No                     | No            | Userspace proxy, same limitation                           |
| vzNAT (`vmType: vz`)  | Yes (bridge)           | Yes           | macOS 13+; creates bridge interface visible to pf          |
| socket_vmnet (shared) | Yes (bridge)           | Yes           | Requires socket_vmnet install; bridge at 192.168.105.0/24  |

**vzNAT is the recommended mode** for this use case: it creates a bridge interface that macOS's `pf` firewall can filter, requires no extra software, and works with `vmType: vz` which we already want for VirtioFS.

#### Layered Egress Control (Defense in Depth)

**Layer 1: In-VM iptables/nftables (default-deny)**
- Unlike containers, in-VM firewall rules are trustworthy -- root inside the VM cannot modify host-level rules.
- Set `OUTPUT` policy to `DROP`, explicitly allow only required destinations.
- Even if an attacker gains root inside the VM, they cannot reach the host kernel's netfilter tables.

**Layer 2: macOS pf on the bridge interface**
- With vzNAT, VM traffic traverses a `bridge100` (or similar) interface on the host.
- `pf` rules targeting that bridge enforce policy at the host kernel level.
- Example: `block drop quick on bridge100 from any to any` + `pass` rules for allowed IPs.
- Configured in `/etc/pf.anchors/` and loaded via `pfctl`.

**Layer 3: DNS filtering**
- Run a local DNS resolver (Unbound or dnsmasq) that only resolves allowed domains.
- Point the VM's DNS at it (via Lima's `hostResolver` or manual `/etc/resolv.conf`).
- Block direct DNS to any other resolver via iptables inside the VM.
- This closes the DNS exfiltration hole that the Docker approach left open.

**Layer 4 (Optional): Host-side egress proxy**
- Lima auto-propagates `HTTP_PROXY`/`HTTPS_PROXY` from the host environment into the guest.
- A proxy like Squid provides application-layer URL filtering and logging.
- Limitation: only affects programs that honor proxy env vars; raw socket connections bypass it.

#### Comparison with Docker Isolation

| Aspect                    | VM (Lima/VZ)                                  | Docker Container                                     |
|---------------------------|-----------------------------------------------|------------------------------------------------------|
| Kernel isolation          | Separate guest kernel                         | Shared host kernel (namespaces only)                 |
| Escape difficulty         | Requires hypervisor exploit (rare)            | Kernel exploit or misconfiguration                   |
| In-environment firewall   | Trustworthy (separate kernel)                 | Untrustworthy (shared kernel, `NET_ADMIN` = bypass)  |
| Host firewall interaction | VM traffic on bridge, filterable by pf        | Docker modifies host iptables, can bypass UFW        |
| Root in environment       | Cannot affect host firewall                   | Can flush host iptables with `NET_ADMIN`             |

---

### 4. VM Lifecycle: Single Long-Lived VM with Mounted Code Tree

Rather than creating one VM per feature branch, the simpler model is a **single VM with the entire code tree mounted via VirtioFS**. Multiple Claude Code sessions run inside the VM, each in a different project/branch directory.

#### Why This Works

- VirtioFS mounts are bidirectional: the host IDE sees changes from the VM immediately, and vice versa.
- The code lives on the host filesystem. The VM contains only the dev tools (Go, Node.js, Claude Code) and the network isolation layer.
- Multiple Claude Code processes can run concurrently in the VM, each with a different working directory.
- If the VM gets corrupted or misconfigured, destroy and recreate it. The code is safe on the host.
- Network and firewall rules apply uniformly to all sessions.

#### VM as Infrastructure, Not Per-Branch Artifact

The VM is provisioned once with all dev tools and kept running. Branch management happens on the host (git checkout, IDE, etc.) and inside the VM (Claude Code sessions). The VM itself is stateless with respect to code -- all state lives on the host via the mount.

This means:
- No clone-per-branch workflow needed.
- No VM name convention tied to branch names.
- No stale-VM cleanup logic.
- Reprovisioning is only needed when the toolchain changes (new Go version, new Claude Code release, etc.).

#### Disposability

The VM is disposable in the sense that it can be destroyed and recreated from the Lima YAML definition at any time. The provisioning cost (3-10 minutes via cloud-init) is paid only when recreating from scratch. For faster recreation, a pre-provisioned base can be cloned via `limactl clone` (15-45 seconds on APFS).

#### Typical Makefile Targets

| Target       | Action                                                            |
|--------------|-------------------------------------------------------------------|
| `vm-create`  | Create and provision the VM from the Lima YAML definition         |
| `vm-destroy` | Stop and delete the VM                                            |
| `vm-start`   | Start a stopped VM                                                |
| `vm-stop`    | Stop the VM without deleting it                                   |
| `vm-ssh`     | SSH into the VM                                                   |
| `vm-exec`    | Run a command inside the VM (`limactl shell`)                     |
| `vm-status`  | Show VM status (running/stopped, resource usage)                  |

---

### 5. Lima YAML Configuration

A Lima YAML file defines the complete VM specification. Key sections for this use case:

```yaml
vmType: vz                   # Apple Virtualization.framework
cpus: 4
memory: "8GiB"
disk: "50GiB"

images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"

mounts:
  - location: "~/src"
    writable: true
    mountType: "virtiofs"

provision:
  - mode: system
    script: |
      #!/bin/bash
      # Install Go, Node.js, Claude Code, dev tools...
```

Template variables available: `{{.Home}}`, `{{.User}}`, `{{.UID}}`, `{{.Name}}`, `{{.Hostname}}`, `{{.Param.Key}}`.

Templates can be stored in `~/.lima/_templates/` and referenced via `limactl create template:<name>`.

---

### 6. Security Improvements Over Docker Approach

| Docker Issue                              | VM Resolution                                                     |
|-------------------------------------------|-------------------------------------------------------------------|
| Self-controlled firewall (NET_ADMIN)      | In-VM iptables are in separate kernel; host pf is unreachable     |
| Root ignores chmod on git hooks           | Can run as non-root user inside VM; or use immutable attrs        |
| DNS exfiltration via open port 53         | Filtering DNS resolver on host; block direct DNS in VM            |
| Container escape via kernel exploits      | Hypervisor boundary; guest kernel is isolated                     |
| No audit logging                          | Host-side pf logging + proxy logging are outside guest control    |
| Shared kernel attack surface              | Eliminated -- separate kernel per VM                              |

---

### 7. Remaining Risks (Shared with Docker Approach)

These are not solved by moving to a VM:

- **Allowlisted domain exfiltration:** If GitHub is allowed for Go modules / git operations, it remains an exfiltration vector. This requires TLS-intercepting proxy or not allowing GitHub at all.
- **Build script poisoning:** Modified Makefiles, go generate directives, etc. still execute on the host if the user runs them without review. The live mount means changes are immediate.
- **Symlink escape:** VirtioFS mounts may follow symlinks created by the agent pointing outside the mounted directory. (Needs testing with Lima's specific VirtioFS implementation.)
- **Git hook injection via host execution:** If the agent modifies `.git/hooks/` inside the VM and the same `.git/` is mounted from the host, running git on the host executes those hooks. This is the same risk as the Docker approach. Mitigation: mount `.git/hooks` read-only, or use `core.hooksPath` on the host pointing to a protected location.

---

### 8. Interesting Side Note: Apple Containers (macOS 26)

At WWDC 2025, Apple announced a native Containerization framework shipping with macOS 26. Each container runs in its own lightweight VM with sub-second startup and hardware-level isolation. This is open-source Swift and may significantly change the landscape. Not yet generally available, but worth monitoring as a potential future simplification.

---

## Open Questions

1. **VirtioFS + inotify reliability:** Does `mountInotify: true` in Lima work well enough for Go test watchers and IDE file detection? Should we plan to run file-watching tools inside the VM instead?

2. **Git hooks on shared mount:** When the project directory (including `.git/`) is mounted via VirtioFS, can we mount `.git/hooks` read-only while keeping the rest writable? Or should we use a different strategy (host-side `core.hooksPath`, `chattr +i` inside VM)?

3. **pf bridge interface stability:** Does the bridge interface name (e.g., `bridge100`) remain stable across VM restarts, or does it change? This affects whether pf rules need dynamic updates.

4. **Lima + VZ + vzNAT maturity:** How stable is the vzNAT networking mode in practice? Are there known issues with dropped connections or DNS resolution failures?

5. **DNS filtering implementation:** Should we run Unbound on the host as a persistent service, or start/stop it with the VM lifecycle? The latter avoids leaving a resolver running when no VM is active.

6. **Credential forwarding:** How should the Anthropic API key (or OAuth credentials) be passed into the VM? Environment variable via Lima's `env` config? Mounted file? The Docker approach used `-e ANTHROPIC_API_KEY` and optional credentials mount.

7. **Claude Code settings/plugins:** The Docker approach mounted `~/.claude/settings.json`, `skills/`, and `plugins/` read-only. Lima's mount config can do the same, but should these live inside the VM (copied at clone time) or be mounted from the host?

8. **Host pf rule management:** Who manages the pf anchor? Should it be part of the VM lifecycle (created on `vm-create`, removed on `vm-destroy`), or a persistent configuration that applies to all VMs on the bridge subnet?

9. **Which Linux distro?** Ubuntu 24.04 is the obvious default (best cloud-init support, widest package availability). Is there a reason to prefer something else?

---

## References

### Existing Code
- `attempt-001-docker/Dockerfile` -- current Docker image definition
- `attempt-001-docker/run.sh` -- current launcher script with mount and credential logic
- `attempt-001-docker/entrypoint.sh` -- current firewall init and hook protection
- `attempt-001-docker/init-firewall.sh` -- current iptables allowlist implementation
- `attempt-001-docker/issues-and-tradeoffs.md` -- audit of Docker approach (Claude-generated)

### External Documentation
- [Lima documentation](https://lima-vm.io/docs/)
- [Lima mount configuration](https://lima-vm.io/docs/config/mount/)
- [Lima network configuration](https://lima-vm.io/docs/config/network/)
- [Lima `limactl clone` reference](https://lima-vm.io/docs/reference/limactl_clone/)
- [Lima `limactl snapshot` reference](https://lima-vm.io/docs/reference/limactl_snapshot/)
- [Tart quick start](https://tart.run/quick-start/)
- [Apple Virtualization.framework networking](https://developer.apple.com/documentation/virtualization/vznetworkdeviceattachment)
- [macOS pf firewall configuration](https://blog.neilsabol.site/post/quickly-easily-adding-pf-packet-filter-firewall-rules-macos-osx/)
- [Cloud-init module reference](https://docs.cloud-init.io/en/latest/reference/modules.html)
- [Sandbox AI dev tools with Lima (Chris Hager)](https://www.metachris.dev/2025/11/sandbox-your-ai-dev-tools-a-practical-guide-for-vms-and-lima/)
- [Isolating network between Tart VMs (Cirrus CI)](https://cirrus-ci.org/blog/2022/07/07/isolating-network-between-tarts-macos-virtual-machines/)
