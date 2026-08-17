# gopher-hole

An exercise in operating isolated, safe coding agents — now a single tool.

Every session answers two questions:

1. **Which agent?** `pi`, `claude`, `codex`, `opencode`, `amp`, or `none` (a
   keyless sandbox shell).
2. **Where does inference run?** A local model (LM Studio, no API key exists),
   or a hosted provider (one spend-capped key per session).

Run `gopher-hole` from the project directory with no arguments, and it walks
you through both questions. Each option shows what it means for credentials.

```
$ gopher-hole
Which agent?
  1. claude   2. codex   3. opencode   4. pi   5. amp   6. none
agent [claude]: 4

Where does inference run?  (pi)
  1. hosted — anthropic  (ANTHROPIC_API_KEY ✓ set)
  2. hosted — openai     (OPENAI_API_KEY ✗ not set)
  3. hosted — bedrock    (AWS_BEARER_TOKEN_BEDROCK ✗ not set)
  4. local — LM Studio detected at localhost:1234 (2 models; no API key enters the guest)
  5. hosted — custom     (CUSTOM_BASE_URL ✗ not set)
inference [anthropic]: 4
launch? [Y/n]
```

Every session runs in a disposable [apple/container](https://github.com/apple/container)
VM: its own guest kernel, sub-second startup, destroyed on exit. Only the
project directory is shared, with `.git` mounted read-only. The agent's own
approval prompts are off — the VM boundary is what makes that safe.

## Usage

```bash
make image          # one-time (and after editing the guest scripts)
make install        # symlink gopher-hole into $CODEPATH/bin (INSTALL_DIR=... to override)

gopher-hole                       # wizard, project = current directory
gopher-hole pi:lmstudio           # explicit pair, no questions
gopher-hole claude ~/src/other    # explicit pair, explicit directory
gopher-hole review                # hunk diff of this project, keyless
gopher-hole shell                 # keyless sandbox shell
gopher-hole --dry-run claude      # print the container invocation, do not run
gopher-hole verify                # smoke tests (also: make verify)
```

## The matrix

The harness and the provider together determine **both** the credential
injected into the guest and the egress allowlist, derived from one table
(`providers.sh`). A `claude:bedrock` session carries only the Bedrock
credential and can reach only the Bedrock endpoint. One session, one provider,
at most one key.

| Harness    | Providers (first = default)                  |
|------------|----------------------------------------------|
| `pi`       | `anthropic openai bedrock lmstudio custom`   |
| `claude`   | `anthropic bedrock custom`                   |
| `codex`    | `openai custom`                              |
| `opencode` | `zen anthropic openai bedrock`               |
| `amp`      | `amp`                                        |
| `none`     | `none`                                       |

`codex:bedrock` is refused: the pinned binary has no verified configuration
path. Put an OpenAI-compatible gateway in front of Bedrock and use
`codex:custom`.

## Two postures

The egress design follows the provider, because the threat model does.

| Concern            | hosted (anthropic, openai, zen, amp, bedrock, custom, none)  | local (`lmstudio`)                    |
|--------------------|--------------------------------------------------------------|---------------------------------------|
| Model egress       | tinyproxy hostname allowlist, CONNECT :443, uid-scoped rules | One nftables rule: LM Studio IP:port  |
| DNS for the agent  | None — only tinyproxy resolves                               | None at all                           |
| Credential         | Exactly one capped key                                       | No key exists                         |
| Toolchain fetches  | Go proxy + npm through the filter; guest-owned caches        | Closed; host `GOMODCACHE` read-only   |
| Egress report      | Printed on session exit                                      | Nothing to report                     |

With a hosted model, exfiltration is not preventable — anything the agent can
read can be encoded into a model request. The controls that matter are what
the agent can read (one directory), what it can do to the host afterwards
(nothing: `.git` is read-only), and how bad a leaked key is (capped,
revocable). With a local model, the crown-jewel credential simply does not
exist, so the local posture keeps egress fully closed — no toolchain fetches,
because `go get` through a proxy is a relay-exfiltration channel.

`none` is keyless but keeps the hosted mechanics, so review and sandbox
sessions can still fetch dependencies through the filter.

## Credentials

**Use a key minted for this purpose, with a hard spend cap, and nothing else.**
Keys pass as env vars only; no host credential file is ever mounted. The
host's `~/.claude`, `~/.codex`, `~/.aws`, and `~/.ssh` never enter the guest.

| Provider    | Required host env var(s)                                    |
|-------------|-------------------------------------------------------------|
| `anthropic` | `ANTHROPIC_API_KEY`                                         |
| `openai`    | `OPENAI_API_KEY`                                            |
| `zen`       | `OPENCODE_API_KEY`                                          |
| `amp`       | `AMP_API_KEY`                                               |
| `bedrock`   | `AWS_BEARER_TOKEN_BEDROCK` (preferred) or access keys       |
| `custom`    | `CUSTOM_BASE_URL`, plus `CUSTOM_API_KEY` if needed          |
| `lmstudio`  | (none — no key exists)                                      |
| `none`      | (none — refuses to carry any)                               |

## LM Studio (the local posture)

Run [LM Studio](https://lmstudio.ai) with a chat model loaded, the server on
port 1234, and **"Serve on Local Network" enabled**. `pi:lmstudio` sessions
regenerate pi's model list from the server at every start, so pi always
matches what LM Studio has loaded.

Environment overrides: `LMSTUDIO_HOST` (an IPv4 literal — a remote model
machine on the LAN), `LMSTUDIO_PORT`, `LMSTUDIO_DEFAULT_MODEL`,
`SHARE_GO_CACHE=0`.

## Other environment overrides

`MODEL`, `BEDROCK_REGIONS`, `CUSTOM_BASE_URL`, `CUSTOM_API_KEY`,
`EGRESS_EXTRA_HOSTS`, `SAFE_PROMPTS=1`, `GOPHER_STATE_DIR`,
`GOPHER_PROXY_PORT` — all carried over from attempt-005 with the same
meanings; see that attempt's README for the full discussion.

## State

Everything that survives a session lives under `~/.gopher-hole`:

```
~/.gopher-hole/
├── state/<harness>-<provider>/   # per-pair harness config and history
└── cache/{go-mod,go-build,npm}/  # guest-owned toolchain caches (hosted only)
```

A leftover `~/.pi-gopher-hole` from attempt-004 migrates to
`state/pi-lmstudio` automatically, once.

## Design history

This tool merges attempt-004 (local model, total lockdown) and attempt-005
(hosted harnesses, filtering proxy). The attempts remain unchanged as the
design record — their READMEs carry the full rationale, risk analysis, and
comparison tables:

- [attempt-001-docker](attempt-001-docker/) — container ergonomics, shared kernel
- [attempt-002-lima](attempt-002-lima/) — real hypervisor, heavyweight lifecycle
- [attempt-003-cloud](attempt-003-cloud/) — strong isolation, latency and cost
- [attempt-004-apple-container](attempt-004-apple-container/) — VM-per-container + local model
- [attempt-005-hosted-harnesses](attempt-005-hosted-harnesses/) — five harnesses, one capped key each
