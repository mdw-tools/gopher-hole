# gopher-hole

A Docker-based environment for running [Claude Code](https://claude.ai/code) with `--dangerously-skip-permissions` on Go projects, while keeping your host machine safe and letting you inspect changes live in your IDE or git UI.

## Rationale

Claude Code's `--dangerously-skip-permissions` flag disables all confirmation prompts, enabling fully autonomous agentic sessions. The tradeoff is that it also disables every safety check — Claude can read, write, and execute anything it can reach without asking. Anthropic's own documentation states this mode should only be used in an isolated environment.

The obvious isolation approach is to give Claude a container with a copy of your source code. The problem is that after the session you need to get the changes back, and inspecting a diff inside a container is awkward. A read-only host mount with a copy-on-write layer solves the isolation but adds friction.

This setup takes a different approach: mount your source directly as a **writable volume**, so your host IDE and git UI see changes in real time, but layer on targeted protections that address the non-obvious risks beyond simple file modification.

## How it works

```
Host filesystem                         Container
──────────────────                      ──────────────────────────────────
~/projects/myrepo  ←── bind mount ──→  /workspace      (read/write)
                                        Claude Code runs here
                                        Firewall blocks unexpected outbound
                                        .git/hooks locked at startup
```

Your files are live on both sides. You review in your IDE as Claude works. When you're satisfied, you commit from the host.

## Components

### `Dockerfile`

Builds on the official `golang:1.26-bookworm` image (Debian-based, not Alpine, for better compatibility with Node.js and glibc-dependent tooling). Installs:

- Go development tools: `gopls`, `delve`, `goimports`
- Node.js 22 and `@anthropic-ai/claude-code`
- `iptables` and `dnsutils` for the firewall

### `init-firewall.sh`

Runs at container startup and configures an outbound allowlist using `iptables`. The approach:

1. Resolves each allowed domain to its current IP addresses via DNS
2. Adds `ACCEPT` rules for those IPs on ports 80 and 443
3. Appends a final `DROP` rule for all other outbound traffic

Allowed domains cover Claude's API, Go module infrastructure, GitHub, and npm. Everything else is blocked, which prevents Claude Code (or a malicious file in your repo) from exfiltrating data to arbitrary hosts.

DNS itself is allowed so that runtime resolution continues to work.

### `entrypoint.sh`

Runs before your command and does two things:

1. Calls `init-firewall.sh` to establish the firewall before any user code runs
2. Locks `.git/hooks` to non-writable — this closes the most dangerous non-obvious attack vector (see Risks below)

### `run.sh`

A convenience wrapper that:

- Defaults the mounted repo to the current directory
- Passes `--cap-add NET_ADMIN` (required for `iptables`)
- Forwards `ANTHROPIC_API_KEY` from the host environment
- Fails fast if the API key is not set

## Usage

**Build the image (once):**

```bash
docker build -t gopher-hole .
```

**Drop to a shell, then launch Claude manually:**

```bash
./run.sh ~/projects/myrepo
# inside the container:
claude --dangerously-skip-permissions
```

This is the recommended flow. You get a shell after Claude exits, so you can run `go test`, inspect state, or relaunch Claude without restarting the container.

**Launch Claude directly:**

```bash
./run.sh ~/projects/myrepo claude --dangerously-skip-permissions
```

The container exits when Claude exits.

**Authentication:**

Three options depending on how you access Claude:

*API key (Console/paid API access):*
```bash
export ANTHROPIC_API_KEY=sk-ant-...
./run.sh ~/projects/myrepo
```

*Subscription — login each session:*
```bash
./run.sh ~/projects/myrepo
# Inside the container:
claude login
# If no browser opens, press 'c' to copy the OAuth URL and paste it into your host browser.
# Login persists for the life of the container but not across restarts.
```

*Subscription — persistent login via mounted credentials:*
```bash
./run.sh --with-credentials ~/projects/myrepo
```
This mounts `~/.claude/.credentials.json` read-only into the container so you stay logged in across restarts. See the Risks section for the tradeoff.

Note: even with a subscription, you can generate an API key at `console.anthropic.com` if you prefer the persistent key approach. API usage is billed separately from subscription fees.

**Host settings and skills** are always mounted read-only into the container:

| Host path                 | Container path                | Purpose                   |
|---------------------------|-------------------------------|---------------------------|
| `~/.claude/settings.json` | `/root/.claude/settings.json` | Preferences, model, theme |
| `~/.claude/skills/`       | `/root/.claude/skills/`       | Custom skill definitions  |
| `~/.claude/plugins/`      | `/root/.claude/plugins/`      | Installed plugins         |

These are read-only so the container inherits your Claude configuration but cannot modify it.

## Risks and mitigations

### File modification or deletion
**Risk:** Claude can freely modify or delete any file under `/workspace`.
**Mitigation:** Your IDE and git UI reflect changes in real time. Review the diff before running anything or committing. Use `git diff` on the host as your checkpoint.

### Git hook injection
**Risk:** Claude modifies `.git/hooks/pre-commit` (or any other hook). The next time you run `git commit`, `git pull`, or `git merge` on the host, that hook executes as your host user with your full privileges.
**Mitigation:** `entrypoint.sh` runs `chmod -R a-w .git/hooks` before Claude starts, making hooks non-writable for the duration of the session. This is the most important protection this setup provides.

### Build script poisoning
**Risk:** Claude modifies `Makefile` targets, `package.json` scripts, `go generate` directives, or similar. If you run those on the host without reviewing them, you execute arbitrary code.
**Mitigation:** Review your diff before running any build or install commands on the host. The git UI review step is your guard here — there is no automatic technical protection against this.

### Data exfiltration
**Risk:** A malicious file in the repo (or a prompt injection in source code Claude reads) instructs Claude to POST your source code or credentials to an external server.
**Mitigation:** The firewall blocks all outbound connections except to explicitly whitelisted domains. An exfiltration attempt to an arbitrary host will be dropped.

### Credential exposure within allowed domains
**Risk:** Even with the firewall, Claude could send data to GitHub or other allowed domains (e.g. by pushing to a remote, creating a gist, or opening an issue).
**Mitigation:** Only use this setup with **trusted repositories**. The firewall restricts destinations but cannot inspect the content of HTTPS traffic to allowed hosts.

### OAuth token exposure (`--with-credentials`)
**Risk:** Mounting `~/.claude/.credentials.json` makes your OAuth token readable inside the container. A malicious repo could use it to make authenticated Anthropic API calls (that domain is in the firewall allowlist), potentially consuming your subscription quota or accessing conversation history.
**Mitigation:** The credentials mount is opt-in (`--with-credentials`) and read-only, so the container cannot modify or exfiltrate it to non-allowlisted hosts. Be especially strict about only using trusted repositories when using this flag. When in doubt, omit the flag and run `claude login` each session instead.

### Settings and skills tampering
**Risk:** `~/.claude/settings.json`, `skills/`, and `plugins/` are mounted from the host.
**Mitigation:** All three are mounted `:ro` (read-only), so the container cannot modify them. A malicious repo cannot use these mounts to persist changes back to your host configuration.

### Symlink escape
**Risk:** Claude creates a symlink inside `/workspace` pointing to a path outside it (e.g. `./secrets -> /etc/passwd`). Following that symlink on the host reads or writes host files outside the repo.
**Mitigation:** Be aware of this when following symlinks from the working directory. Inspect new symlinks in your git diff before following them.

### Firewall IP staleness
**Risk:** The firewall resolves domain IPs once at container startup. If a CDN rotates IPs mid-session, connections to that domain may start failing.
**Mitigation:** Restart the container to re-resolve. This is an operational inconvenience, not a security issue.

### `NET_ADMIN` capability
**Risk:** `--cap-add NET_ADMIN` is required for `iptables` and gives the container elevated network privileges. It does not allow escaping the container, but it is broader than a minimal container.
**Mitigation:** This is an accepted tradeoff for having the firewall at all. The alternative is `--network none`, which breaks Claude Code's API connection entirely.

## What this does not protect against

- **Malicious repos.** If you clone and run an untrusted repository, Claude could be manipulated by content in that repo before you have a chance to review it. Only use this with code you own or have audited.
- **Host-side execution of modified files.** Once you copy or run anything from the container's output on the host, you are responsible for having reviewed it first.
- **Container escape vulnerabilities.** This setup does not harden the container against kernel-level exploits. It assumes a standard threat model where the container boundary holds. This setup's load-bearing assumption is that we will always operate on trusted repositories, so the additional isolation a VM would provide isn't strictly necessary in this case.
