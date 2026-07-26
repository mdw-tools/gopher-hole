#!/bin/bash
# Launch one hosted coding harness inside a disposable apple/container VM,
# sharing only the project directory.
#
# Usage:
#   ./run.sh <harness> [PROJECT_DIR] [COMMAND...]
#
#   <harness>  claude | codex | opencode | amp | none
#
# Examples:
#   ./run.sh claude ~/src/myproject         # claude, auto-approving, in that dir
#   ./run.sh codex  ~/src/myproject         # codex, approvals off
#   ./run.sh none   ~/src/myproject         # sandbox shell, no model access
#   ./run.sh none   ~/src/myproject hunk diff   # review the changes it made
#
# The harness is positional and required because the credential injected into
# the guest depends on it: a claude session carries no OpenAI key, and vice
# versa. One session, one harness, one key.
#
# Environment (optional):
#   EGRESS_EXTRA_HOSTS  comma-separated extra hostnames to allow this session
#   SAFE_PROMPTS=1      keep the harness's own approval prompts on
#   GOPHER_STATE_DIR    where per-harness state and caches live
#                       (default ~/.gopher-hole)
set -euo pipefail

IMAGE="gopher-hole-hosted"
STATE_ROOT="${GOPHER_STATE_DIR:-${HOME}/.gopher-hole}"

usage() {
  echo "usage: $0 <claude|codex|opencode|amp|none> [PROJECT_DIR] [COMMAND...]" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
HARNESS="$1"; shift

case "$HARNESS" in
  claude|codex|opencode|amp|none) ;;
  *) echo "error: unknown harness '${HARNESS}'" >&2; usage ;;
esac

PROJECT_DIR="${1:-$(pwd)}"
shift || true

# Resolve symlinks so the host path and the in-guest mount agree exactly
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd -P)

ENV_ARGS=(--env "GOPHER_HARNESS=${HARNESS}")
MOUNTS=()

# --- credentials -----------------------------------------------------------
# Passed as env vars only; no host credential file is ever mounted. Use keys
# minted for this purpose with a hard spend cap — not your subscription's OAuth
# token, whose blast radius is the whole account. See README "Credentials".
require_key() {
  local var="$1"
  if [[ -z "${!var:-}" ]]; then
    echo "error: ${HARNESS} needs ${var} set in your host environment." >&2
    echo "       Use a dedicated, spend-capped key — see README 'Credentials'." >&2
    exit 1
  fi
  ENV_ARGS+=(--env "${var}=${!var}")
}

case "$HARNESS" in
  claude) require_key ANTHROPIC_API_KEY ;;
  codex)  require_key OPENAI_API_KEY ;;
  amp)    require_key AMP_API_KEY ;;
  opencode)
    # Provider-agnostic: pass whichever provider keys are set, require one.
    for var in ANTHROPIC_API_KEY OPENAI_API_KEY; do
      [[ -n "${!var:-}" ]] && ENV_ARGS+=(--env "${var}=${!var}")
    done
    if [[ -z "${ANTHROPIC_API_KEY:-}${OPENAI_API_KEY:-}" ]]; then
      echo "error: opencode needs ANTHROPIC_API_KEY or OPENAI_API_KEY set." >&2
      exit 1
    fi
    ;;
  none) ;;  # deliberately keyless
esac

[[ -n "${EGRESS_EXTRA_HOSTS:-}" ]] && ENV_ARGS+=(--env "EGRESS_EXTRA_HOSTS=${EGRESS_EXTRA_HOSTS}")

# A non-default proxy port has to move the client env too, or the harnesses
# would keep dialling the image's baked-in 8888 and get dropped.
if [[ -n "${GOPHER_PROXY_PORT:-}" ]]; then
  PROXY_URL="http://127.0.0.1:${GOPHER_PROXY_PORT}"
  ENV_ARGS+=(--env "GOPHER_PROXY_PORT=${GOPHER_PROXY_PORT}" \
             --env "HTTP_PROXY=${PROXY_URL}"  --env "HTTPS_PROXY=${PROXY_URL}" \
             --env "http_proxy=${PROXY_URL}"  --env "https_proxy=${PROXY_URL}")
fi

# --- per-harness state ------------------------------------------------------
# Dedicated dirs under ~/.gopher-hole. The host's own ~/.claude, ~/.codex etc.
# are never mounted: they hold credentials, history, MCP tokens and your global
# instructions, none of which belong in a guest running unattended.
if [[ "$HARNESS" != "none" ]]; then
  STATE="${STATE_ROOT}/state/${HARNESS}"
  mkdir -p "$STATE"
  case "$HARNESS" in
    claude)
      MOUNTS+=(--volume "${STATE}:/home/agent/.claude")
      ENV_ARGS+=(--env "CLAUDE_CONFIG_DIR=/home/agent/.claude")
      ;;
    codex)
      MOUNTS+=(--volume "${STATE}:/home/agent/.codex")
      ENV_ARGS+=(--env "CODEX_HOME=/home/agent/.codex")
      ;;
    opencode)
      mkdir -p "${STATE}/config" "${STATE}/data"
      MOUNTS+=(--volume "${STATE}/config:/home/agent/.config/opencode" \
               --volume "${STATE}/data:/home/agent/.local/share/opencode")
      ;;
    amp)
      MOUNTS+=(--volume "${STATE}:/home/agent/.config/amp")
      ;;
  esac
fi

# --- toolchain caches -------------------------------------------------------
# Guest-owned and writable, persisted across sessions so builds are fast after
# the first. Deliberately NOT the host's real caches: attempt-004 shared the
# host Go module cache read-only because egress was fully closed, but here the
# Go proxy is reachable through the filter, so the guest can just fetch its own
# and the host's cache stays out of reach entirely.
CACHE="${STATE_ROOT}/cache"
mkdir -p "${CACHE}/go-mod" "${CACHE}/go-build" "${CACHE}/npm"
MOUNTS+=(--volume "${CACHE}/go-mod:/home/agent/go/pkg/mod" \
         --volume "${CACHE}/go-build:/home/agent/.cache/go-build" \
         --volume "${CACHE}/npm:/home/agent/.npm")
ENV_ARGS+=(--env "GOMODCACHE=/home/agent/go/pkg/mod" \
           --env "GOCACHE=/home/agent/.cache/go-build" \
           --env "npm_config_cache=/home/agent/.npm")

# --- git identity, no host gitconfig ---------------------------------------
GIT_NAME=$(git config --global user.name 2>/dev/null || true)
GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
[[ -n "$GIT_NAME" ]] && ENV_ARGS+=(--env "GIT_AUTHOR_NAME=${GIT_NAME}" --env "GIT_COMMITTER_NAME=${GIT_NAME}")
[[ -n "$GIT_EMAIL" ]] && ENV_ARGS+=(--env "GIT_AUTHOR_EMAIL=${GIT_EMAIL}" --env "GIT_COMMITTER_EMAIL=${GIT_EMAIL}")

# --- read-only .git ---------------------------------------------------------
# The agent edits the working tree freely but cannot write commits, config,
# hooks or filter drivers. This closes the path where poisoned git metadata
# executes when YOU run git on the host — the main host-compromise vector for
# an agent that is otherwise confined to a VM. You commit and push from the
# host after reviewing the diff.
GIT_MOUNT=()
GIT_DIR_PATH="${PROJECT_DIR}/.git"
if [[ -d "$GIT_DIR_PATH" ]]; then
  GIT_MOUNT+=(--volume "${GIT_DIR_PATH}:${GIT_DIR_PATH}:ro")
elif [[ -e "$GIT_DIR_PATH" ]]; then
  echo "note: ${GIT_DIR_PATH} is a file (worktree/submodule) — read-only .git protection skipped." >&2
fi

# --- default command --------------------------------------------------------
# No command given: launch the harness with its approvals off, because the VM
# boundary is what makes that safe. SAFE_PROMPTS=1 keeps them on.
if [[ $# -eq 0 ]]; then
  case "$HARNESS" in
    claude)
      if [[ "${SAFE_PROMPTS:-0}" == "1" ]]; then set -- claude
      else set -- claude --dangerously-skip-permissions; fi
      ;;
    codex)    set -- codex ;;     # approvals off via config.toml
    opencode) set -- opencode ;;  # permissions allowed via opencode.json
    amp)      set -- amp ;;
    none)     set -- bash ;;
  esac
fi

# Allocate a TTY only when we have one (verify.sh runs without)
TTY_ARGS=()
[[ -t 0 ]] && TTY_ARGS+=(-it)

# CAP_NET_ADMIN lets the entrypoint's root stage install the nftables ruleset in
# the guest's own kernel; setpriv strips it before the agent user runs, so the
# agent can neither flush nor read the ruleset.
exec container run --rm \
  --cap-add CAP_NET_ADMIN \
  ${TTY_ARGS[@]+"${TTY_ARGS[@]}"} \
  --volume "${PROJECT_DIR}:${PROJECT_DIR}" \
  ${GIT_MOUNT[@]+"${GIT_MOUNT[@]}"} \
  ${MOUNTS[@]+"${MOUNTS[@]}"} \
  --workdir "${PROJECT_DIR}" \
  ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  "${IMAGE}" "$@"
