# Proposal: Lima + VirtioFS VM for Isolated Agent Environment

## Background

The Docker-based approach (`attempt-001-docker/`) provides agent isolation but has fundamental architectural weaknesses: the firewall is self-controlled (the container holds `NET_ADMIN`), root ignores `chmod` protections on git hooks, DNS port 53 is wide open, and the container shares the host kernel.

A Lima VM with Apple's Virtualization.framework (`vmType: vz`) addresses all of these:

- The VM has its own kernel — in-VM firewall rules are enforced by a separate kernel unreachable from the guest process.
- Lima runs a non-root user by default — nftables rules set during provisioning (as root) cannot be modified by the Claude Code process.
- DNS goes through Lima's host-agent resolver, not via direct outbound connections — no open port 53 to arbitrary servers.
- The hypervisor boundary is fundamentally stronger than namespace isolation.

VirtioFS provides ~70-90% native filesystem speed for the bidirectional host mount, so the host IDE sees changes in real time.

## Approach

### Architecture

```
Host (macOS)                               VM (Ubuntu 24.04 / Lima)
────────────────────                       ──────────────────────────────────────
~/src  ←── VirtioFS (rw) ──→              /Users/<user>/src
                                            Claude Code runs here
                                            nftables allowlist (non-root can't modify)
                                            DNS via Lima host-agent only

~/.claude  ←── VirtioFS (ro) ──→          /Users/<user>/.claude (read-only)
                                            Settings, skills, plugins inherited

ANTHROPIC_API_KEY  ──→  env var ──→        Available to Claude Code process
```

A single long-lived VM with the entire code tree (`~/src`) mounted writable. Multiple Claude Code sessions can run concurrently in different working directories. The VM is disposable — destroy and recreate from the YAML definition at any time; code is safe on the host.

### Key Design Decisions

**Lima with `vmType: vz`, not Tart or others.**
VZ gives VirtioFS and vzNAT networking natively. Lima has cloud-init for declarative provisioning. Tart lacks cloud-init and is oriented toward CI/CD. OrbStack shares the host kernel (weaker isolation). The others (UTM, Multipass, Colima) have worse automation or filesystem performance.

**Single VM with mounted code tree, not one VM per branch.**
Simpler lifecycle. The VM is infrastructure (like Docker Desktop), not a per-branch artifact. Branch management happens on the host and inside the VM. No clone/cleanup workflow needed.

**In-VM nftables as the primary firewall, not host-side pf (for now).**
Lima runs Claude Code as a non-root user. Nftables rules set during provisioning (as root) cannot be modified by the agent process. This is already a major improvement over Docker where the container ran as root with `NET_ADMIN`. Host-side pf can be added later as defense-in-depth but isn't required for the trust model to hold.

**Lima's hostResolver for DNS, not a custom filtering resolver (for now).**
DNS queries from the VM go through Lima's host-agent, which resolves via macOS DNS. The VM cannot contact arbitrary DNS servers directly (nftables blocks it). DNS exfiltration via query names remains a theoretical risk — the host-agent would resolve `secret.attacker.com` via macOS DNS, which contacts the attacker's nameserver. A filtering resolver (Unbound) can be added later to close this. For an experiment where we control the repos, this is an acceptable residual risk.

**Mount `~/.claude` read-only, not copy-on-provision.**
Keeps host settings, skills, and plugins in sync without reprovisioning. Claude Code inside the VM reads config from the mount. If Claude Code needs writable state (conversation history, etc.), Lima's default user has a writable home directory where Claude Code can create its own `~/.claude/` — but the read-only mount takes precedence at the mount point. We'll need to handle this by mounting specific subdirectories or symlinking. If this proves too complex, we fall back to copying settings during provisioning.

**Environment variable for API key, not mounted credentials file.**
Simpler and avoids persisting secrets on disk inside the VM. Passed at session launch time via `limactl shell --env`.

**Ubuntu 24.04 LTS.**
Best cloud-init support, widest package availability, long-term support. No reason to choose anything else for this use case.

### File Structure

```
attempt-002-lima/
├── gopher-hole.yaml      # Lima VM definition (resources, mounts, provisioning)
├── provision.sh           # Tool installation (Go, Node.js, Claude Code)
├── init-firewall.sh       # nftables allowlist setup
├── run.sh                 # Convenience wrapper for launching Claude Code sessions
├── Makefile               # VM lifecycle targets
└── README.md              # Usage, risks, comparison to Docker approach
```

### Firewall Allowlist

Same domains as the Docker approach, enforced via nftables (set-based matching, more efficient than iptables linear rules):

```
# Claude API
api.anthropic.com
statsig.anthropic.com

# Go modules
proxy.golang.org
sum.golang.org
golang.org
gopkg.in
storage.googleapis.com

# Source / VCS
github.com
api.github.com
raw.githubusercontent.com
objects.githubusercontent.com
codeload.github.com

# npm
registry.npmjs.org
```

DNS is restricted to the Lima host-agent resolver address only. All other outbound traffic is dropped. HTTPS only (port 443) — no port 80.

### Git Hook Protection

The agent can still modify `.git/hooks/` on the shared mount. Options considered:

1. **`chattr +i` inside the VM** — immutable attribute, works for non-root user. But requires ext4/btrfs on the mount. VirtioFS may or may not support extended attributes. Needs testing.
2. **Separate read-only mount for `.git/hooks`** — Lima can mount subdirectories independently, but this adds YAML complexity and may conflict with the parent writable mount.
3. **`core.hooksPath` on the host** — set `git config core.hooksPath ~/.git-hooks` on the host, pointing to a directory outside the mounted tree. Hooks in `.git/hooks/` are then ignored by git. This is the most reliable approach.

For this experiment, we'll document option 3 as a recommendation and verify whether `chattr +i` works over VirtioFS.

## Trade-offs & Risks

### Improvements over Docker

| Concern                     | Docker                                         | Lima VM                                             |
|-----------------------------|-------------------------------------------------|-----------------------------------------------------|
| Firewall bypassable        | Root + NET_ADMIN = can flush iptables           | Non-root user can't modify nftables                 |
| Git hook chmod ineffective  | Root ignores file permissions                   | Non-root user respects permissions; chattr possible |
| DNS exfiltration            | Open port 53 to any server                      | DNS only via host-agent; no direct outbound DNS     |
| Kernel isolation            | Shared host kernel                              | Separate guest kernel (hypervisor boundary)         |
| Audit logging               | Inside container, controllable by agent          | Host-side pf/proxy logging possible (future)        |

### Remaining risks (same as Docker)

- **Allowlisted domain exfiltration.** GitHub is an exfiltration vector. Cannot be fixed without removing GitHub from the allowlist or adding TLS inspection.
- **Build script poisoning.** Modified Makefiles etc. execute on the host if the user runs them without review.
- **Git hook injection via host.** Even with in-VM protection, if `.git/hooks/` is modified and the user runs git on the host, hooks execute. Mitigation: `core.hooksPath` on the host.

### New risks introduced

- **VirtioFS maturity.** VirtioFS on Apple's Virtualization.framework is relatively new. Potential for data corruption or performance issues under heavy I/O.
- **Lima VZ + vzNAT stability.** Less battle-tested than Docker. May encounter bugs with networking or mount handling.
- **inotify unreliable.** File watchers inside the VM may not receive all filesystem events from host-side changes. Affects Go test watchers. Mitigation: use polling or run watchers on the host.
- **`~/.claude` mount complexity.** Read-only mount may conflict with Claude Code's need to write state. May need to adjust mount strategy during implementation.
- **Provisioning time.** First VM creation takes 3-10 minutes (cloud-init downloads and installs tools). Subsequent starts are fast (seconds). Acceptable for an experiment.

### Open questions deferred to implementation

- Does `chattr +i` work over VirtioFS?
- Does `mountInotify: true` help with Go test watchers?
- Is the bridge interface name stable across VM restarts (matters if we add pf later)?

## Implementation Checklist

### Phase 1: Minimal bootable VM with VirtioFS mount

- [ ] Create `attempt-002-lima/` directory
- [ ] Write `gopher-hole.yaml` with: `vmType: vz`, Ubuntu 24.04 ARM64 image, 4 CPUs, 8 GiB RAM, 50 GiB disk, writable VirtioFS mount of `~/src`
- [ ] Verify: `limactl create --name=gopher-hole ./gopher-hole.yaml && limactl start gopher-hole` boots successfully
- [ ] Verify: `limactl shell gopher-hole` drops to a shell
- [ ] Verify: files in `~/src` on the host are visible and writable inside the VM at the expected mount point
- [ ] Verify: changes made inside the VM are immediately visible on the host

### Phase 2: Dev tool provisioning

- [ ] Write `provision.sh` — installs Go (latest stable), Node.js 22, Claude Code (`@anthropic-ai/claude-code`), and essential dev tools (`git`, `make`, `curl`, `build-essential`)
- [ ] Reference `provision.sh` from `gopher-hole.yaml` as a `mode: system` provisioning script
- [ ] Verify: recreate the VM (`limactl delete gopher-hole && limactl create ...`) and confirm provisioning runs
- [ ] Verify: `go version`, `node --version`, `claude --version` all succeed inside the VM

### Phase 3: Firewall (nftables allowlist)

- [ ] Write `init-firewall.sh` — resolves allowed domains to IPs, creates nftables rules: default-deny OUTPUT, allow loopback, allow established, allow HTTPS (443 only) to allowed IPs, allow DNS only to Lima host-agent address, drop everything else
- [ ] Reference `init-firewall.sh` from `provision.sh` (runs at provisioning time; rules persist across reboots via nftables service)
- [ ] Verify: `curl https://api.anthropic.com` succeeds (allowed domain)
- [ ] Verify: `curl https://example.com` fails/times out (blocked domain)
- [ ] Verify: `dig @8.8.8.8 example.com` fails (direct DNS to external resolver blocked)
- [ ] Verify: `dig example.com` succeeds (DNS via Lima host-agent works)
- [ ] Verify: the non-root user cannot run `nft flush ruleset` (permission denied)

### Phase 4: Credential forwarding and `~/.claude` mount

- [ ] Add read-only VirtioFS mount of `~/.claude` to `gopher-hole.yaml`
- [ ] Verify: `~/.claude/settings.json` is readable inside the VM
- [ ] Verify: writing to the `~/.claude` mount point inside the VM fails (read-only)
- [ ] Write `run.sh` — wrapper that runs `limactl shell gopher-hole --workdir <dir>` with `ANTHROPIC_API_KEY` forwarded from the host environment; accepts a project directory argument (defaults to cwd); optionally accepts a command (defaults to `claude --dangerously-skip-permissions`)
- [ ] Verify: `ANTHROPIC_API_KEY=test ./run.sh ~/src/myproject` enters the VM in the right directory with the env var set
- [ ] Test whether Claude Code can read settings from the read-only mount. If not, adjust strategy (symlink writable dirs, copy on launch, etc.)

### Phase 5: Makefile and lifecycle

- [ ] Write `Makefile` with targets: `vm-create`, `vm-destroy`, `vm-start`, `vm-stop`, `vm-ssh`, `vm-status`
- [ ] Verify: `make vm-create` provisions the VM from scratch
- [ ] Verify: `make vm-destroy && make vm-create` produces a working VM (disposability)
- [ ] Verify: `make vm-ssh` drops to a shell inside the VM

### Phase 6: Documentation

- [ ] Write `README.md` covering: rationale, how it works (architecture diagram), components, usage (build, launch, authentication), risks and mitigations, comparison to Docker approach, known limitations
- [ ] Document `core.hooksPath` recommendation for git hook protection on the host
- [ ] Document residual risks honestly (DNS exfiltration via query names, GitHub exfiltration, VirtioFS maturity)
