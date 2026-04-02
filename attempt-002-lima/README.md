# attempt-002-lima: Lima + VirtioFS VM for Isolated Agent Environment

## Rationale

The Docker-based approach (`attempt-001-docker/`) has fundamental architectural weaknesses:

- The firewall is self-controlled (the container holds `NET_ADMIN` and runs as root)
- Root ignores `chmod` protections on git hooks
- DNS port 53 is wide open to arbitrary servers
- The container shares the host kernel

A Lima VM with Apple's Virtualization.framework (`vmType: vz`) addresses all of these by providing a separate kernel, a non-root user that cannot modify firewall rules, and DNS restricted to Lima's host-agent resolver.

## Architecture

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

A single long-lived VM with the entire code tree (`~/src`) mounted writable. Multiple Claude Code sessions can run concurrently in different working directories. The VM is disposable — destroy and recreate from the YAML definition at any time; code lives safely on the host.

## Components

| File               | Purpose                                                     |
|--------------------|-------------------------------------------------------------|
| `gopher-hole.yaml` | Lima VM definition (resources, mounts, provisioning)        |
| `provision.sh`     | Tool installation (Go, Node.js, Claude Code, dev tools)     |
| `init-firewall.sh` | nftables allowlist setup                                    |
| `run.sh`           | Convenience wrapper for launching Claude Code sessions      |
| `Makefile`         | VM lifecycle targets                                        |

## Prerequisites

- macOS with Apple Silicon (Virtualization.framework requires ARM64)
- [Lima](https://lima-vm.io/): `brew install lima`

## Usage

### Create the VM

```bash
make vm-create
```

This downloads the Ubuntu 24.04 ARM64 image, boots the VM, and runs provisioning (Go, Node.js, Claude Code, nftables firewall). First creation takes 3-10 minutes.

### Launch a Claude Code session

```bash
# Set your API key
export ANTHROPIC_API_KEY="sk-ant-..."

# Launch Claude Code in a project directory
./run.sh ~/src/github.com/myorg/myproject

# Or drop to a bash shell
./run.sh ~/src/github.com/myorg/myproject bash
```

### VM lifecycle

```bash
make vm-start    # start the VM
make vm-stop     # stop the VM
make vm-ssh      # open a shell in the VM
make vm-status   # check VM status
make vm-destroy  # delete the VM entirely (code on host is safe)
```

### Authentication

**API key (recommended for experiments):**
Set `ANTHROPIC_API_KEY` in your host environment. `run.sh` forwards it to the VM.

**Subscription login:**
Run `claude login` inside the VM. Session state is stored in the VM's writable home directory.

## Firewall

nftables rules enforce an allowlist of domains:

- **Claude API:** api.anthropic.com, statsig.anthropic.com
- **Go modules:** proxy.golang.org, sum.golang.org, golang.org, gopkg.in, storage.googleapis.com
- **Source/VCS:** github.com, api.github.com, raw.githubusercontent.com, objects.githubusercontent.com, codeload.github.com
- **npm:** registry.npmjs.org

DNS is restricted to the Lima host-agent resolver. All other outbound traffic is dropped. HTTPS only (port 443).

The non-root user running Claude Code cannot modify these rules.

## Comparison to Docker Approach

| Concern                    | Docker (attempt-001)                           | Lima VM (attempt-002)                               |
|----------------------------|------------------------------------------------|-----------------------------------------------------|
| Firewall bypassable        | Root + NET_ADMIN = can flush iptables          | Non-root user can't modify nftables                 |
| Git hook chmod ineffective | Root ignores file permissions                  | Non-root user respects permissions; chattr possible |
| DNS exfiltration           | Open port 53 to any server                     | DNS only via host-agent; no direct outbound DNS     |
| Kernel isolation           | Shared host kernel                             | Separate guest kernel (hypervisor boundary)         |
| Filesystem performance     | Docker bind mount                              | VirtioFS (~70-90% native speed)                     |

## Risks and Mitigations

### Residual risks (same as Docker)

- **Allowlisted domain exfiltration.** GitHub is an exfiltration vector. Cannot be fixed without removing GitHub from the allowlist or adding TLS inspection.
- **Build script poisoning.** Modified Makefiles execute on the host if the user runs them without review.
- **Git hook injection.** Even with in-VM protection, `.git/hooks/` modifications on the shared mount execute if git runs on the host.

### Mitigation: git hook protection

Set `core.hooksPath` on the host to point outside the mounted tree:

```bash
git config --global core.hooksPath ~/.git-hooks
```

This causes git to ignore `.git/hooks/` entirely, preventing hook injection via the shared mount.

### Risks specific to Lima approach

- **VirtioFS maturity.** Relatively new on Apple's Virtualization.framework. Potential for data corruption under heavy I/O.
- **Lima VZ + vzNAT stability.** Less battle-tested than Docker.
- **inotify unreliable.** File watchers inside the VM may miss host-side changes. Use polling or host-side watchers.
- **DNS exfiltration via query names.** Lima's host-agent resolves queries via macOS DNS. A query to `secret.attacker.com` would reach the attacker's nameserver. Acceptable residual risk for controlled experiments; fixable with a filtering resolver (Unbound).

## Known Limitations

- First VM creation takes 3-10 minutes (cloud-init downloads and installs tools)
- The `~/.claude` read-only mount may conflict with Claude Code's need to write state; adjust mount strategy if needed
- `chattr +i` for git hook immutability over VirtioFS is untested
- Bridge interface name stability across VM restarts is unverified (matters for future host-side pf rules)
