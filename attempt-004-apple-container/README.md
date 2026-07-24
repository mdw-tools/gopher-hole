# attempt-004-apple-container: Apple Containers + pi + LM Studio + hunk

## Rationale

Every prior attempt traded something away: Docker (attempt-001) had container
ergonomics but a shared kernel and a self-controlled firewall; Lima
(attempt-002) had a real hypervisor boundary but heavyweight VM lifecycle;
the cloud (attempt-003) had strong isolation but latency, cost, and cloud
credentials.

Apple's open-source [`container`](https://github.com/apple/container) tool
collapses that trade: **every container runs in its own lightweight VM** with
a separate guest kernel, sub-second startup, and ordinary OCI images. This
attempt combines it with a fully local model, so the usual crown-jewel
credential (the API key) simply does not exist inside the guest:

- **Harness:** the [pi coding agent](https://github.com/badlogic/pi-mono),
  talking to **LM Studio on the host** via an OpenAI-compatible endpoint.
  Model traffic never leaves the machine.
- **Review:** [hunk](https://github.com/modem-dev/hunk), a terminal diff TUI
  built for reviewing agent-authored changesets.
- **Sharing:** only the project directory is bind-mounted (at its host
  absolute path), live in both directions. Nothing else from `$HOME` enters
  the guest.

### Why not `container machine`?

Apple's container *machines* (systemd-booted VMs) share the **entire**
`$HOME` or nothing (`--home-mount ro|rw|none`, verified against CLI 1.1.0) —
handing the agent `~/.ssh` and all. Plain `container run` supports
per-directory `--volume` mounts with identical VM-per-container isolation,
and nothing here needs systemd. So: plain containers.

## Architecture

```
Host (macOS 26, Apple Silicon)             Disposable container (own VM, Ubuntu 24.04)
──────────────────────────────             ────────────────────────────────────────────
LM Studio :1234  ←── HTTP via gateway ───  pi coding agent (non-root 'agent' user)
                     (192.168.64.1)
project dir      ←── -v "$PWD:$PWD" ────→  same path inside guest (only dir shared)
~/.pi-gopher-hole ←─ -v ...:/home/agent/.pi → pi sessions/config persist across runs
```

## Components

| File               | Purpose                                                         |
|--------------------|-----------------------------------------------------------------|
| `Dockerfile`       | Toolbox image: git, hunk, pi, Go 1.26, Node 22, python3, perl   |
| `entrypoint.sh`    | Root stage: firewall, drop to `agent`; then pi setup + hand-off |
| `init-firewall.sh` | nftables default-drop egress allowlist (guest kernel)           |
| `setup-pi.sh`      | In-guest: detects gateway, generates pi's `models.json`         |
| `run.sh`           | Host-side session launcher                                      |
| `Makefile`         | `image`, `verify`, `clean` targets                              |
| `verify.sh`        | Smoke tests (the red/green driver for this attempt)             |

## Prerequisites

- macOS 26 on Apple Silicon
- [`container`](https://github.com/apple/container) CLI ≥ 1.1.0
  (`brew install container`), started once via `container system start`
- [LM Studio](https://lmstudio.ai) with:
  - at least one chat-capable model loaded
  - the server running on port 1234
  - **“Serve on Local Network” enabled** — the server binds loopback-only by
    default, and the guest's connection is refused until this is on

## Usage

```bash
# one-time
make image

# each session — disposable container, only the project dir shared
./run.sh ~/src/myproject              # drop to bash in that dir
./run.sh ~/src/myproject pi           # launch pi directly
./run.sh ~/src/myproject hunk diff    # review agent changes in the TUI

# smoke tests
make verify
```

Sessions are disposable: every `run.sh` invocation boots a fresh VM (~0.6s)
and `--rm`s it on exit. The only state that survives is the project directory
and `~/.pi-gopher-hole` (pi sessions, provider config) — exactly the state
worth keeping. Concurrent sessions on different projects are just concurrent
`run.sh` invocations, each in its own VM.

Environment overrides for `run.sh`:

| Variable                 | Effect                                          |
|--------------------------|--------------------------------------------------|
| `LMSTUDIO_PORT`          | Host port LM Studio serves on (default: 1234)   |
| `LMSTUDIO_DEFAULT_MODEL` | Model id pi defaults to (default: first listed) |

## Model wiring

At container start, `setup-pi.sh` detects the vmnet gateway (the host) from
the guest's default route, queries LM Studio's `/v1/models`, and regenerates
`models.json` with one entry per loaded chat model — so pi's model list always
matches what LM Studio actually has loaded. `defaultProvider`/`defaultModel`
are pinned in pi's `settings.json` without clobbering other settings.

## Reviewing changes with hunk

```bash
./run.sh ~/src/myproject hunk diff
```

Optionally, make hunk the default git pager so `git diff`/`git show` inside
the container open the TUI automatically. There is no shared global gitconfig
(by design — no `~/.gitconfig` enters the guest), so set it **per repository**,
which persists because the project directory lives on the host:

```bash
./run.sh ~/src/myproject bash
git config core.pager "hunk pager"
```

Note that this also affects git on the host (same repo, same config file);
if you'd rather keep host git untouched, skip the config and invoke
`hunk diff` explicitly.

## Comparison to prior attempts

| Concern              | 001 Docker            | 002 Lima              | 003 Cloud          | 004 Apple Containers    |
|----------------------|-----------------------|-----------------------|--------------------|-------------------------|
| Kernel isolation     | Shared host kernel    | Separate guest kernel | Separate machine   | Separate kernel per VM  |
| Filesystem exposure  | Project dir           | All of `~/src`        | rsync'd copy       | Project dir only        |
| API key in guest     | Yes                   | Yes                   | Yes                | **No key exists**       |
| Model traffic        | Internet              | Internet              | Internet           | Host-local only         |
| Session startup      | ~1s                   | Minutes (VM boot)     | Minutes (provision)| ~0.6s                   |
| Credentials in guest | Optional mounts       | Via shared home       | SSH agent forward  | None                    |

## Risks and mitigations

- **LM Studio LAN exposure.** “Serve on Local Network” binds all interfaces,
  so other devices on your LAN can reach the model server. Acceptable on a
  trusted network; otherwise restrict with the macOS application firewall.
- **Git hook / build-script poisoning.** Unchanged from prior attempts: the
  agent can write `.git/hooks/` and Makefiles in the shared project dir, and
  those execute if you run git/make on the host. Mitigation:
  `git config --global core.hooksPath ~/.git-hooks` on the host, and review
  build-file diffs (hunk!) before running anything.
- **Egress allowlist.** Sessions launched via `run.sh` get a default-drop
  nftables policy in the guest kernel allowing only: LM Studio via the
  gateway, DNS via the gateway resolver, and HTTPS to github.com,
  bitbucket.org, and the Go module proxy. `run.sh` passes
  `--cap-add CAP_NET_ADMIN` so the entrypoint's root stage can install the
  rules — safe because the capability governs only this container's own VM
  kernel, and `setpriv` strips it before the agent user runs (the agent
  cannot flush or even read the ruleset — unlike attempt-001, where the same
  capability against a shared kernel was the top audit finding). Residual
  risk shared with attempt-002: DNS query names to the gateway resolver
  remain an exfiltration channel, and allowlisted hosts (github) are
  themselves exfiltration targets.
- **No credentials in the guest (by design).** `git push`/`pull` against
  remotes happens on the host after review. For `go get` of private modules,
  supply a read-only app password per-session as an env var if ever needed.

## Troubleshooting

- **`pi` says “No API key found”** — `setup-pi.sh` couldn't reach LM Studio.
  Check the server is running and “Serve on Local Network” is enabled, then
  start a new session.
- **Stray containers.** If the host-side `container run` process is killed
  (rather than exiting), `--rm` doesn't fire and the VM lingers. List with
  `container ls`, stop with `container stop <id>`.
- **`container system status` claims the apiserver isn't running** even when
  commands work — observed under sandboxed shells; trust `container ls`.
