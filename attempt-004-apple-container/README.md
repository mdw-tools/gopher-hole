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

| File               | Purpose                                                                        |
|--------------------|--------------------------------------------------------------------------------|
| `Dockerfile`       | Toolbox image: git, build-essential, hunk, pi, Go 1.26, Node 22, python3, perl |
| `entrypoint.sh`    | Root stage: firewall, drop to `agent`; then pi setup + hand-off                |
| `init-firewall.sh` | nftables default-drop egress; LM Studio only (VCS opt-in)                      |
| `setup-pi.sh`      | In-guest: detects gateway, generates pi's `models.json`                        |
| `run.sh`           | Host-side session launcher                                                     |
| `Makefile`         | `image`, `verify`, `clean` targets                                             |
| `verify.sh`        | Smoke tests (the red/green driver for this attempt)                            |

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

| Variable                 | Effect                                                           |
|--------------------------|------------------------------------------------------------------|
| `LMSTUDIO_HOST`          | IPv4 of a remote LM Studio machine (default: the container host) |
| `LMSTUDIO_PORT`          | Port LM Studio serves on (default: 1234)                         |
| `LMSTUDIO_DEFAULT_MODEL` | Model id pi defaults to (default: first listed)                  |
| `EGRESS_ALLOW_VCS=1`     | Also allow in-guest `git`/`go get` (default: LM Studio only)     |
| `SHARE_GO_CACHE=0`       | Don't share the host Go module cache (default: on, read-only)    |

## Session posture: read-only `.git` + locked-down egress

Two defenses apply automatically to every `run.sh` session:

- **Read-only `.git`.** The repo's `.git` directory is mounted read-only, so
  the agent edits the working tree freely but cannot write commits, config,
  hooks, or filter drivers. This closes the vector where poisoned git metadata
  would execute when *you* run git on the host. You author commits and push
  from the host after review — the working-tree changes are plain files, so
  host `git status`/`git diff` see them normally.
- **Locked-down egress.** By default the only reachable network destination is
  LM Studio on the host gateway. Git and `go get` are expected to run on the
  host, so no VCS/DNS egress is allowed (this also closes the DNS-query
  exfiltration channel). Set `EGRESS_ALLOW_VCS=1` to re-enable in-guest
  `git`/`go get` against github, bitbucket, and the Go module proxy.

### Go module cache

To make `go build`/`go test` work under the lockdown, `run.sh` shares the host
Go module cache (`go env GOMODCACHE`) into the guest **read-only** by default,
sets `GOMODCACHE` to it, gives the guest its own build cache, and sets
`GOPROXY=off`. Module source is platform-independent, so the guest (linux)
builds fine against the host's (darwin) downloads; the *build* cache is not
shared because compiled objects are OS/arch-specific. Read-only means the
agent can't poison a cache your host also uses, and `GOPROXY=off` makes a
missing module fail fast instead of stalling on the firewall.

The consequence: the agent can build/test against anything **already fetched
on the host**, but a genuinely new dependency needs a deliberate step — either
`go mod download` on the host, or an `EGRESS_ALLOW_VCS=1` session (which skips
the read-only share and lets the guest fetch into its own cache). Set
`SHARE_GO_CACHE=0` to skip the share entirely; it's also skipped automatically
when Go isn't installed on the host or when `EGRESS_ALLOW_VCS=1`.

### Single-repo vs. a tree of repos

The read-only `.git` protection covers **one** top-level `.git` directory —
i.e. `./run.sh` pointed at a single project. If you point it at a parent
directory containing several repos, only egress protects you, not the mount:
each nested `.git` stays writable, and any repo the agent creates mid-session
is unprotected regardless. Prefer one repo per session; if you must share a
tree, rely on the locked-down egress and review every diff on the host before
running git there. A `.git` *file* (submodule/linked worktree) can't be
protected this way either — `run.sh` prints a note and skips the read-only
mount in that case.

## Model wiring

At container start, `setup-pi.sh` detects the vmnet gateway (the host) from
the guest's default route — or uses `LMSTUDIO_HOST` if set (see below) —
then queries LM Studio's native REST API
(`/api/v0/models`), and regenerates `models.json` with one entry per chat
model — so pi's model list always matches what LM Studio actually has loaded.
Each model's `contextWindow` is set dynamically: `loaded_context_length`
(the enforceable limit for a currently loaded model) when available, else
the model's `max_context_length`, else 128000. If the native API is
unavailable (older LM Studio), it falls back to the OpenAI-compat
`/v1/models` with the 128000 default. `defaultProvider`/`defaultModel` are
pinned in pi's `settings.json` without clobbering other settings.

### Remote LM Studio (`LMSTUDIO_HOST`)

To run containers on one machine and the models on another, set
`LMSTUDIO_HOST` to the model machine's LAN address:

```bash
LMSTUDIO_HOST=192.168.1.42 ./run.sh ~/src/myproject pi
```

`setup-pi.sh` then targets that address instead of the gateway, and the
firewall's single allowed destination moves with it — the gateway itself
becomes unreachable from the guest. The value must be an IPv4 literal (the
guest has no DNS under locked egress, so a hostname could neither be resolved
by curl nor pinned by nftables); `run.sh` rejects anything else. The model
machine needs LM Studio's "Serve on Local Network" enabled, and the container
machine's macOS must grant `container` local-network access.

The scripts are baked into the image, so run `make image` after changing them
— a stale image silently keeps the old firewall. To verify the remote setup
from the container machine (whose own host runs no LM Studio, so the default
gateway checks would fail there):

```bash
LMSTUDIO_HOST=192.168.1.42 ./verify.sh pi firewall
```

Two posture changes to be aware of in this mode: model traffic (prompts and
code context) crosses the LAN as cleartext HTTP rather than staying
host-local, and the guest's one allowed egress destination is now a second
machine — so the "Model traffic: host-local only" row in the comparison table
below no longer applies. If either bothers you, the alternative is a
host-side relay (e.g. an ssh `-L` tunnel from the container machine to the
model machine) with `LMSTUDIO_HOST` unset, which keeps the guest pinned to
the gateway and encrypts the LAN leg.

## Reviewing changes with hunk

```bash
./run.sh ~/src/myproject hunk diff
```

Optionally, make hunk the default git pager so `git diff`/`git show` inside
the container open the TUI automatically. Because `.git` is mounted read-only,
set this **on the host** (it writes `.git/config`, which the guest cannot):

```bash
git -C ~/src/myproject config core.pager "hunk pager"
```

The setting then applies to git both on the host and in the guest (same repo,
same config file). If you'd rather keep host git untouched, skip it and invoke
`hunk diff` explicitly.

## Comparison to prior attempts

| Concern              | 001 Docker            | 002 Lima              | 003 Cloud          | 004 Apple Containers    |
|----------------------|-----------------------|-----------------------|--------------------|-------------------------|
| Kernel isolation     | Shared host kernel    | Separate guest kernel | Separate machine   | Separate kernel per VM  |
| Filesystem exposure  | Project dir           | All of `~/src`        | rsync'd copy       | Project dir (`.git` ro) |
| API key in guest     | Yes                   | Yes                   | Yes                | **No key exists**       |
| Model traffic        | Internet              | Internet              | Internet           | Host-local only         |
| Default egress       | Allowlist             | Allowlist             | Open               | LM Studio only          |
| Session startup      | ~1s                   | Minutes (VM boot)     | Minutes (provision)| ~0.6s                   |
| Credentials in guest | Optional mounts       | Via shared home       | SSH agent forward  | None                    |

## Risks and mitigations

- **LM Studio LAN exposure.** “Serve on Local Network” binds all interfaces,
  so other devices on your LAN can reach the model server. Acceptable on a
  trusted network; otherwise restrict with the macOS application firewall.
- **Git metadata poisoning.** Largely closed by the read-only `.git` mount
  (see above): the agent cannot write hooks, config, or filter drivers for a
  single-repo session. Two residues remain: build scripts (Makefiles,
  `go generate`) in the working tree still execute if you run them on the
  host — review build-file diffs in `hunk` first — and the read-only mount
  does not cover a tree of repos or mid-session `git init` (see the
  multi-repo note above). Belt-and-suspenders: keep
  `git config --global core.hooksPath ~/.git-hooks` on the host.
- **Egress lockdown.** Sessions get a default-drop nftables policy in the
  guest kernel; by default only LM Studio via the gateway is reachable (no
  git, no DNS — so no DNS-query exfiltration either). `EGRESS_ALLOW_VCS=1`
  widens it to DNS + github/bitbucket/Go proxy for in-guest fetches, at which
  point DNS query names and allowlisted hosts become exfiltration channels
  again (the attempt-002 residual). `run.sh` passes `--cap-add CAP_NET_ADMIN`
  so the entrypoint's root stage can install the rules — safe because the
  capability governs only this container's own VM kernel, and `setpriv`
  strips it before the agent user runs (the agent cannot flush or even read
  the ruleset — unlike attempt-001, where the same capability against a
  shared kernel was the top audit finding).
- **`safe.directory=*` in the guest.** The image trusts any repo ownership so
  git works on the host-owned mount. This only affects the throwaway guest;
  no host git config is changed.
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
