# attempt-005-hosted-harnesses: Apple Containers + claude/codex/opencode/amp

## Rationale

attempt-004's thesis was *no credential exists in the guest* — a local model on
hardware powerful enough to run one. Away from that hardware the model must be
hosted, which changes the problem rather than weakening it:

**With a hosted model, exfiltration is no longer preventable.** Every byte the
agent can read can be encoded into a model request, and the model endpoint has
to be reachable or the tool does not work. So the controls that matter are not
"can data leave" but:

1. **What can the agent read at all?** One project directory. Nothing else from
   `$HOME` — not `~/.ssh`, not the browser profile, not `~/Documents`, not the
   host's own `~/.claude`.
2. **What can it do to the host afterwards?** Nothing: `.git` is read-only, so
   it cannot plant a hook or filter driver that executes when *you* run git.
3. **How bad is the credential if it leaks?** One dedicated, spend-capped,
   revocable API key — never a subscription OAuth token, whose blast radius is
   the whole account.

The payoff of getting those three right is that you can turn the harness's own
approval prompts **off** and stop babysitting it, because the blast radius is a
disposable VM plus one directory. That is the thesis of this attempt.

## Architecture

```
Host (macOS 26, Apple Silicon)          Disposable container (own VM, Ubuntu 24.04)
──────────────────────────────          ────────────────────────────────────────────
                                        ┌─ root stage: nftables + tinyproxy ───┐
                                        │  then setpriv → 'agent', caps dropped│
                                        └──────────────────────────────────────┘
                                        agent (non-root)
                                          │  HTTPS_PROXY=127.0.0.1:8888
                                          ▼
api.anthropic.com  ←── :443 ────────── tinyproxy  (hostname allowlist, logged)
  (or openai/ampcode, per harness)        ▲
                                          └── anything else: DROP
project dir      ←── -v "$PWD:$PWD" ───→  same path in guest (only dir shared)
  └── .git       ─── mounted :ro ──────→  read-only
~/.gopher-hole/state/<harness>  ───────→  that harness's config only
~/.gopher-hole/cache/{go,npm}   ───────→  guest-owned build caches
```

## Components

| File                | Purpose                                                                           |
|---------------------|-----------------------------------------------------------------------------------|
| `Dockerfile`        | Toolbox: 5 harnesses (pinned), hunk, Go 1.26, Node 22, tinyproxy, build-essential |
| `providers.sh`      | **The harness × provider matrix — single source of truth**, sourced host and guest |
| `entrypoint.sh`     | Root stage: proxy + firewall (fail closed), drop to `agent`; then session         |
| `init-firewall.sh`  | tinyproxy allowlist + nftables uid-scoped egress — the core of the design         |
| `setup-harness.sh`  | Per-pair config: approvals off, in-tool sandboxes off, provider wiring           |
| `egress-report.sh`  | End-of-session summary of every host reached and refused                          |
| `run.sh`            | Host-side launcher; picks the pair, injects exactly one credential                |
| `verify.sh`         | Smoke tests, including the negative claims (the red/green driver)                 |
| `Makefile`          | `image`, `verify`, `clean`                                                        |

## Prerequisites

- macOS 26 on Apple Silicon
- [`container`](https://github.com/apple/container) CLI ≥ 1.1.0
  (`brew install container`), started once via `container system start`
- A dedicated API key for whichever harness you use (see **Credentials**)

## Usage

```bash
# one-time
make image

# each session — disposable VM, one pair, one credential, one directory
./run.sh claude   ~/src/myproject          # claude → anthropic (its default)
./run.sh claude:bedrock ~/src/myproject    # claude → AWS Bedrock
./run.sh codex    ~/src/myproject          # codex → openai
./run.sh opencode ~/src/myproject          # opencode → Zen (its default)
./run.sh opencode:bedrock ~/src/myproject  # opencode → Bedrock
./run.sh pi:openai ~/src/myproject         # pi → OpenAI
./run.sh none     ~/src/myproject          # sandbox shell, no model access
./run.sh none     ~/src/myproject hunk diff   # review what it did

MODEL=claude-sonnet-4-5 ./run.sh claude ~/src/myproject   # pin a model

make verify
```

Both halves of `<harness>:<provider>` are load-bearing: **together they determine
the credential injected into the guest AND the egress allowlist**, derived from
the same table. A `claude:bedrock` session carries only the Bedrock credential
and can reach only the Bedrock endpoint — not `api.anthropic.com`. Omit the
provider to get that harness's default.

Environment overrides:

| Variable             | Effect                                                              |
|----------------------|---------------------------------------------------------------------|
| `MODEL`              | Model id to pin for this session                                    |
| `BEDROCK_REGIONS`    | Comma-separated regions to allow (default `$AWS_REGION`)            |
| `CUSTOM_BASE_URL`    | `provider=custom`: the endpoint; its host is what gets allowlisted   |
| `CUSTOM_API_KEY`     | `provider=custom`: bearer key, if the endpoint needs one             |
| `EGRESS_EXTRA_HOSTS` | Comma-separated extra hostnames to allow for this session            |
| `SAFE_PROMPTS=1`     | Keep the harness's own approval prompts on (claude)                  |
| `GOPHER_STATE_DIR`   | Where state and caches live (default `~/.gopher-hole`)               |
| `GOPHER_PROXY_PORT`  | In-guest proxy port (default 8888)                                  |

## Provider matrix

Every cell below was established by reading the **pinned harness binaries**, not
the documentation — `providers.sh` carries the same table in executable form, and
`verify.sh`'s `matrix` section asserts all 11 valid pairs.

| Harness    | Providers (first = default)                | Notes                                        |
|------------|--------------------------------------------|----------------------------------------------|
| `claude`   | `anthropic`, `bedrock`, `custom`           | `CLAUDE_CODE_USE_BEDROCK`; also knows Vertex/Foundry |
| `codex`    | `openai`, `custom`                         | Bedrock **excluded** — see below              |
| `opencode` | `zen`, `anthropic`, `openai`, `bedrock`    | `amazon-bedrock` provider via models.dev      |
| `pi`       | `anthropic`, `openai`, `bedrock`, `custom` | wire formats incl. `bedrock-converse-stream`  |
| `amp`      | `amp`                                      | server-side routing only; no provider choice  |
| `none`     | `none`                                     | keyless sandbox shell                         |

**Why `codex:bedrock` is refused.** The codex binary does contain a
`BedrockApiKeyAuth` variant, but it sits in a concatenated string table with no
discoverable config key and no `bedrock-runtime` endpoint anywhere in the
binary — so there was no way to verify a configuration path. Shipping a guess
would produce a session that silently fails to authenticate, so the pair is
rejected with a message pointing at the alternative: put an OpenAI-compatible
gateway in front of Bedrock and use `codex:custom` with `CUSTOM_BASE_URL`.
`run.sh` prints exactly that hint.

The `custom` provider is the general escape hatch — any endpoint, with only its
hostname allowlisted. It covers gateways, LiteLLM-style translators, and a local
LM Studio if you are ever back on capable hardware (which is attempt-004's whole
arrangement, reachable from here with one flag).

## Egress: a filtering proxy, not an IP allowlist

This is the main departure from attempts 001–004, which resolved a list of
domains at container start and pinned the resulting addresses in nftables. That
approach **does not work** for hosted model APIs: `api.anthropic.com`,
`api.openai.com` and `ampcode.com` sit behind large, short-TTL address pools, so
startup-pinned addresses go stale mid-session. The failure surfaces as an
intermittently broken harness rather than as a firewall error — the worst kind
of bug to debug.

Instead, the guest runs `tinyproxy` bound to loopback with
`FilterDefaultDeny Yes`, making the filter file a whitelist of anchored,
dot-escaped hostnames, and `ConnectPort 443` so `CONNECT` cannot become a
general TCP tunnel. nftables then permits outbound 443 **only from tinyproxy's
uid**:

```
policy drop
accept  oif lo                              # agent → proxy
accept  ct state established,related
accept  meta skuid <tinyproxy> tcp dport 443
accept  meta skuid <tinyproxy> ip daddr <resolver> udp/tcp dport 53
```

Three properties fall out of this that the IP approach could not give:

- **CDN-fronted hosts work reliably** — filtering is on the hostname in the
  `CONNECT` request, so rotating addresses are irrelevant.
- **The agent user has no DNS at all.** Only tinyproxy resolves, and only names
  that already passed the filter. So DNS-query exfiltration stays closed even
  though the model API is reachable — a property attempt-002 and attempt-004's
  `EGRESS_ALLOW_VCS` mode both had to give up.
- **Every destination is logged.** `egress-report.sh` prints a per-session
  summary when the session exits. Since the allowlist is not a confidentiality
  boundary, visibility is the compensating control: an unexpected host there is
  worth investigating.

  ```
  --- egress summary (this session) ---
  reached:
        2 api.anthropic.com
  refused (not on the allowlist):
        1 evil.example.com
  ```

  "reached" comes from tinyproxy's *established connection* lines, not its
  request lines — the request is logged before filtering, so parsing those
  reports refused hosts as reached, which is precisely backwards for the one
  thing this report exists to tell you. `verify.sh`'s `report` section pins that
  distinction.

The agent cannot subvert any of it. The proxy config and filter file are
root-owned, the ruleset lives in a guest kernel it has no access to, and
`setpriv` strips `CAP_NET_ADMIN` before the session command runs — `verify.sh`
checks that the agent can neither read the ruleset nor append to the allowlist.

Egress setup failure is **fatal** here, unlike attempt-004 where the fallback
was harmless (no rules, no credentials, nothing to lose). A session that came up
without the ruleset would be an unfiltered agent holding a real API key.

### Toolchain fetches

`proxy.golang.org`, `sum.golang.org`, `storage.googleapis.com` and
`registry.npmjs.org` are allowed in every posture, so in-guest `go get` and
`npm install` just work — Go and npm both honour `HTTPS_PROXY`. This removes
attempt-004's read-only host-module-cache arrangement entirely: the guest keeps
its own caches under `~/.gopher-hole/cache`, persisted across sessions, and the
host's real caches are never mounted (asserted in `verify.sh`).

## Credentials

**Use a key minted for this purpose, with a hard spend cap, and nothing else.**

The credential follows the **provider**, not the harness:

| Provider    | Required host env var(s)                                              |
|-------------|-----------------------------------------------------------------------|
| `anthropic` | `ANTHROPIC_API_KEY`                                                   |
| `openai`    | `OPENAI_API_KEY`                                                      |
| `zen`       | `OPENCODE_API_KEY`                                                    |
| `amp`       | `AMP_API_KEY`                                                         |
| `bedrock`   | `AWS_BEARER_TOKEN_BEDROCK` (preferred) or `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` |
| `custom`    | `CUSTOM_BASE_URL`, plus `CUSTOM_API_KEY` if the endpoint needs one     |
| `none`      | (none — refuses to carry any)                                         |

**Only the selected provider's credential enters the guest**, even when every
other key is sitting right there in your host environment. `verify.sh`'s
`creds_matrix` section proves this for all 11 pairs by setting decoy values for
every credential the matrix knows and asserting each session carries its own and
only its own.

- **Keys are passed as env vars only.** No host credential file is ever mounted.
  `run.sh` refuses to launch a harness whose key is missing rather than starting
  a session that will fail halfway through.
- **Don't use subscription OAuth.** A Max/Pro OAuth token in a guest risks the
  whole account and has no spend ceiling; a scoped API key is bounded and
  revocable in one click. It also sidesteps the login flow, which wants a
  browser the guest does not have.
- **Assume any key in the guest is reachable by anything the agent runs** — a
  poisoned dependency or an instruction embedded in repo content can read the
  environment. That is why the credential is per-pair and capped, not shared.
- The host's own `~/.claude`, `~/.codex`, `~/.aws` and friends are never mounted.
  Each pair gets a dedicated dir under `~/.gopher-hole/state`, keyed by harness
  AND provider, so a `claude:anthropic` session and a `claude:bedrock` session
  cannot fight over each other's config. `verify.sh` asserts `~/.ssh`,
  `~/.claude` and `~/.aws` are invisible in the guest.

### Bedrock without widening the blast radius

Bedrock was the one addition that threatened principle #3, because AWS
credentials are categorically broader than a model API key: `AWS_ACCESS_KEY_ID`
plus a secret is a foothold in your account bounded only by IAM, not "one
spend-capped model endpoint."

**`AWS_BEARER_TOKEN_BEDROCK` avoids that** — it is a Bedrock-scoped bearer
credential, and all three Bedrock-capable harnesses here support it (verified in
each binary). With one, Bedrock costs essentially nothing in posture:

- **Use a Bedrock API key, short-term variety.** Time-bounded, so a leak decays
  on its own — arguably better than a static Anthropic key.
- **`run.sh` prefers it and warns loudly on the fallback.** If only
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are present it will proceed, but
  prints a warning that the principal must be able to do nothing but
  `bedrock:InvokeModel*`. `AWS_SESSION_TOKEN` is forwarded when set, since STS
  credentials expire on their own.
- **Never mount `~/.aws`.** opencode's binary carries the full AWS SDK chain
  (`AWS_CONFIG_FILE`, `AWS_CONTAINER_CREDENTIALS_FULL_URI`, …), so an accidental
  mount would be picked up silently. `verify.sh` asserts it is invisible; that
  test is load-bearing rather than decorative.
- **The endpoint is region-scoped** (`bedrock-runtime.<region>.amazonaws.com`).
  Cross-region inference profiles fan out across several regional endpoints, so
  `BEDROCK_REGIONS=us-east-1,us-west-2` widens the allowlist accordingly. The
  egress summary is how you find out you needed it.

Note what the firewall does and does not buy here. A Bedrock session can reach
only the Bedrock endpoint, so over-broad AWS credentials cannot be used against
S3 or IAM **from inside the guest**. But a credential that leaks out through the
model channel can be used from anywhere, so IAM scoping is the real control and
the allowlist is only depth.

### opencode Zen: one credential, many models

opencode ships its own pay-per-usage gateway ("Zen") at `opencode.ai/zen/v1`,
billed by opencode and reached with a single `OPENCODE_API_KEY`. It is
`opencode`'s **default provider** because it fits this design better than direct
provider keys: a leak exposes one revocable, independently spend-capped key
rather than every provider key you own, and the session's allowlist narrows to
the gateway so it cannot reach `api.anthropic.com` or `api.openai.com` at all.

Pick a different provider explicitly when you want one:

```bash
./run.sh opencode           ~/src/myproject   # → zen (default)
./run.sh opencode:anthropic ~/src/myproject   # → api.anthropic.com
./run.sh opencode:bedrock   ~/src/myproject   # → bedrock-runtime.<region>
```

Conversation sharing is off (`OPENCODE_DISABLE_SHARE=1`); it would post session
content to opencode's servers.

## MCP servers: the hole to watch

MCP servers silently defeat the read-only `.git`. A GitHub MCP server with a
broadly-scoped token lets the guest push to every repo you own, straight past
the mount protection — the credential is the boundary breach, not the
filesystem. None are configured here by design. If you add one, add it alone,
with a fine-grained token scoped to specific repos, and add its host to
`EGRESS_EXTRA_HOSTS` deliberately.

## Host-side hygiene (not enforced by this container)

- `git config --global core.hooksPath ~/.git-hooks` (an empty dir) — belt and
  suspenders behind the read-only `.git`.
- **Keep agent-touched repos off iCloud Drive and Dropbox.** Guest writes sync
  to the cloud immediately, before you have reviewed anything.
- Working backups, so a destructive mistake is boring rather than catastrophic.
- Push from the host after reviewing the diff (`./run.sh none <dir> hunk diff`).

## Per-harness notes

- **claude** — auto-approval is the `--dangerously-skip-permissions` launch
  flag, applied by `run.sh`; it refuses to run as root, which is fine since the
  session user is `agent`. `SAFE_PROMPTS=1` keeps prompts on.
- **codex** — configured via `$CODEX_HOME/config.toml`
  (`approval_policy = "never"`, `sandbox_mode = "danger-full-access"`), written
  once on first run and never overwritten. Codex's own sandbox uses
  Landlock/seccomp, which the guest kernel may not provide; deferring to the VM
  boundary avoids a failure mode that buys nothing here.

  It honours `OPENAI_API_KEY` directly — no `codex login`, so the missing browser
  never comes up. It prefers a WebSocket transport
  (`wss://api.openai.com/v1/responses`) and falls back to HTTPS; tinyproxy
  tunnels both through the same `CONNECT`, so neither needs special handling.

  Expect these in the egress summary, **refused and harmless**:

  ```
  refused (not on the allowlist):
        2 chatgpt.com          # ChatGPT-plan auth probe — irrelevant with an API key
        1 github.com           # update / release check
        1 api.github.com
  ```

  Codex completes its API call regardless, so they stay off the allowlist. This
  is the egress report doing its job: three phone-homes that no amount of
  reading the docs would have told you about.
- **opencode** — `permission: {edit, bash, webfetch: "allow"}` merged into
  `opencode.json`, so hand edits to other keys survive. Needs `models.dev` for
  its model catalog, allowlisted for this harness only. Conversation sharing is
  off (`OPENCODE_DISABLE_SHARE=1`) — it would post session content to opencode's
  servers. Prefers Zen; see **Credentials**.
- **pi** — the most provider-agnostic of the five: its `Api` union covers
  `anthropic-messages`, `openai-completions`, `openai-responses`,
  `bedrock-converse-stream`, `google-vertex` and more. Set `MODEL` to pin one and
  `setup-harness.sh` generates `~/.pi/agent/models.json` accordingly; without
  `MODEL` it falls back to pi's own built-in provider defaults, which are a
  better guess than anything invented here. Installed with `--ignore-scripts`
  (no postinstall), like hunk.
- **amp** — routes models server-side, so it cannot be pointed at a local model
  and always needs a real Amp credential. It is the one harness flexibility
  cannot reach. Its auto-approval setting is not pinned down here, so it runs at
  defaults and **will still prompt**.

## Supply chain

`--ignore-scripts` (used by attempts 001–004) cannot be used for three of the
four harnesses: `@anthropic-ai/claude-code`, `opencode-ai` and amp (via
`@ampcode/cli`) all resolve their platform binary in a `postinstall` script, so
ignoring scripts installs a CLI that cannot start. Only `@openai/codex` is
script-free. Install scripts therefore run at **image build time**, on **pinned
versions**, in a throwaway image — never during a session.

Every version is a `Dockerfile` `ARG`, and all four self-updaters are disabled
(`DISABLE_AUTOUPDATER`, `OPENCODE_DISABLE_AUTOUPDATE`) along with telemetry.
An agent that silently updates itself mid-session is not a repeatable
experiment; bump the ARG and rebuild instead.

## Comparison to prior attempts

| Concern              | 002 Lima              | 003 Cloud           | 004 Local model         | 005 Hosted harnesses         |
|----------------------|-----------------------|---------------------|-------------------------|------------------------------|
| Kernel isolation     | Separate guest kernel | Separate machine    | Separate kernel per VM  | Separate kernel per VM       |
| Filesystem exposure  | All of `~/src`        | rsync'd copy        | Project dir (`.git` ro) | Project dir (`.git` ro)      |
| Credential in guest  | Yes                   | Yes                 | **None**                | One capped key per session   |
| Harness choice       | One (claude)          | One (claude)        | One (pi)                | Five, one per session        |
| Provider choice      | Fixed                 | Fixed               | LM Studio only          | Per-session, 6 providers     |
| Model traffic        | Internet              | Internet            | Host-local only         | Internet (hostname-filtered) |
| Egress mechanism     | IP allowlist          | Open                | LM Studio only          | Filtering proxy + uid rules  |
| DNS exfil channel    | Open                  | Open                | Closed                  | **Closed**                   |
| Egress visibility    | None                  | None                | None                    | Per-session log + summary    |
| Approval prompts     | On                    | On                  | On                      | **Off** (VM is the boundary) |

## Risks and residues

- **Exfiltration via the model API is possible by construction.** Not a defect
  to patch — it is what the tool does. The mount list is the real control, and
  the egress log is the visibility.
- **Approvals are off by default.** Deliberate, and the reason the rest of the
  design has to hold. A `.git` that were writable, or an extra mounted
  directory, would make this reckless rather than bounded.
- **Read-only `.git` means the agent cannot commit.** Intended: "agent writes a
  git hook, you run git on the host" is precisely the host-compromise path this
  is built to stop. You commit from the host after review.
- **Single-repo protection only.** The read-only `.git` covers one top-level
  `.git` directory. Point `run.sh` at a parent of several repos and only egress
  protects you; a `.git` *file* (submodule/linked worktree) can't be protected
  this way either — `run.sh` prints a note and skips the mount.
- **Cost.** Real money per session, in a VM you deliberately let run unattended.
  Spend caps on the keys are not optional.
- **Tools that ignore `HTTPS_PROXY`** would be dropped by nftables rather than
  silently escaping — fail closed and loud, which is the right direction, but if
  a harness misbehaves this is the first thing to check.
- **`safe.directory=*` in the guest.** The image trusts any repo ownership so
  git works on the host-owned mount. Affects only the throwaway guest.

## Troubleshooting

- **Everything network fails immediately** — check the harness's own name is
  spelled right; an unknown `GOPHER_HARNESS` aborts the session, and a harness
  whose endpoint isn't in its allowlist gets a 403 from the proxy.
- **`container system start` reports an XPC connection error** — observed under
  sandboxed shells. Run it from a normal terminal.
- **Stray containers.** If the host-side `container run` process is killed
  rather than exiting, `--rm` doesn't fire and the VM lingers. `container ls`,
  then `container stop <id>`.
- **A refusal you didn't expect in the egress summary** — that's the feature.
  Find out what asked for it before widening the allowlist.
