#!/bin/bash
# Launch one hosted coding harness inside a disposable apple/container VM,
# sharing only the project directory.
#
# Usage:
#   ./run.sh <harness>[:<provider>] [PROJECT_DIR] [COMMAND...]
#
#   <harness>   claude | codex | opencode | pi | amp | none
#   <provider>  anthropic | openai | bedrock | zen | amp | custom | none
#               omitted → that harness's default (see providers.sh)
#
# Examples:
#   ./run.sh claude ~/src/myproject            # claude → anthropic (its default)
#   ./run.sh claude:bedrock ~/src/myproject    # claude → AWS Bedrock
#   ./run.sh opencode ~/src/myproject          # opencode → Zen (its default)
#   ./run.sh opencode:openai ~/src/myproject   # opencode → OpenAI directly
#   ./run.sh pi:bedrock ~/src/myproject        # pi → Bedrock
#   ./run.sh none ~/src/myproject hunk diff    # review changes, no model access
#
# harness and provider together determine BOTH the credential injected into the
# guest and the egress allowlist, derived from the same table (providers.sh). A
# claude:bedrock session carries only the Bedrock credential and can reach only
# the Bedrock endpoint — not api.anthropic.com. One session, one provider, one key.
#
# Environment (optional):
#   MODEL               model id to pin for this session
#   BEDROCK_REGIONS     comma-separated regions to allow (default $AWS_REGION)
#   CUSTOM_BASE_URL     provider=custom: the endpoint (its host is allowlisted)
#   CUSTOM_API_KEY      provider=custom: bearer key, if the endpoint needs one
#   EGRESS_EXTRA_HOSTS  comma-separated extra hostnames to allow this session
#   SAFE_PROMPTS=1      keep the harness's own approval prompts on
#   GOPHER_STATE_DIR    where per-harness state and caches live
#                       (default ~/.gopher-hole)
set -euo pipefail

IMAGE="gopher-hole-hosted"
HERE=$(cd "$(dirname "$0")" && pwd -P)
STATE_ROOT="${GOPHER_STATE_DIR:-${HOME}/.gopher-hole}"

# shellcheck source=providers.sh
. "${HERE}/providers.sh"

usage() {
  echo "usage: $0 <harness>[:<provider>] [PROJECT_DIR] [COMMAND...]" >&2
  echo "  harnesses and their providers (first = default):" >&2
  local h
  for h in $(all_harnesses); do
    printf '    %-9s %s\n' "$h" "$(harness_providers "$h")" >&2
  done
  exit 2
}

[[ $# -ge 1 ]] || usage
SPEC="$1"; shift

HARNESS="${SPEC%%:*}"
if [[ "$SPEC" == *:* ]]; then PROVIDER="${SPEC#*:}"; else PROVIDER=""; fi

harness_providers "$HARNESS" >/dev/null 2>&1 || {
  echo "error: unknown harness '${HARNESS}'" >&2; usage; }

[[ -n "$PROVIDER" ]] || PROVIDER=$(harness_default_provider "$HARNESS")

harness_supports "$HARNESS" "$PROVIDER" || {
  echo "error: harness '${HARNESS}' does not support provider '${PROVIDER}'." >&2
  echo "       supported: $(harness_providers "$HARNESS")" >&2
  if [[ "$HARNESS" == "codex" && "$PROVIDER" == "bedrock" ]]; then
    echo "       codex has no verified Bedrock configuration path; put an" >&2
    echo "       OpenAI-compatible gateway in front of Bedrock and use" >&2
    echo "       codex:custom with CUSTOM_BASE_URL. See README." >&2
  fi
  exit 1
}

PROJECT_DIR="${1:-$(pwd)}"
shift || true

# Resolve symlinks so the host path and the in-guest mount agree exactly
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd -P)

ENV_ARGS=(--env "GOPHER_HARNESS=${HARNESS}" --env "GOPHER_PROVIDER=${PROVIDER}")
MOUNTS=()

[[ -n "${MODEL:-}" ]] && ENV_ARGS+=(--env "MODEL=${MODEL}")

# --- credentials -----------------------------------------------------------
# Exactly ONE provider's credential enters the guest, chosen by the matrix. No
# host credential file is ever mounted, and no other provider's key is forwarded
# even when it is sitting right there in your host environment — so a leak
# exposes one revocable, spend-capped key rather than every key you own.
missing_key() {
  echo "error: ${HARNESS}/${PROVIDER} needs $* set in your host environment." >&2
  echo "       Use a dedicated, spend-capped key — see README 'Credentials'." >&2
  exit 1
}

case "$PROVIDER" in
  bedrock)
    # AWS_BEARER_TOKEN_BEDROCK is a Bedrock-SCOPED credential. AWS_ACCESS_KEY_ID
    # is a general AWS credential whose blast radius is whatever IAM permits —
    # a categorically worse thing to hand an unattended agent. Prefer the bearer
    # token; warn loudly on the fallback rather than silently degrading.
    if [[ -n "${AWS_BEARER_TOKEN_BEDROCK:-}" ]]; then
      ENV_ARGS+=(--env "AWS_BEARER_TOKEN_BEDROCK=${AWS_BEARER_TOKEN_BEDROCK}")
    elif [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
      echo "warning: using general AWS credentials rather than a Bedrock API key." >&2
      echo "         AWS_BEARER_TOKEN_BEDROCK is scoped to Bedrock; access keys are" >&2
      echo "         scoped to whatever IAM allows. Ensure this principal can do" >&2
      echo "         nothing but bedrock:InvokeModel*. See README." >&2
      ENV_ARGS+=(--env "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}" \
                 --env "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}")
      # Short-lived STS credentials decay on their own — strictly preferable
      [[ -n "${AWS_SESSION_TOKEN:-}" ]] \
        && ENV_ARGS+=(--env "AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}")
    else
      missing_key "AWS_BEARER_TOKEN_BEDROCK (preferred) or AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY"
    fi
    AWS_REGION_EFF="${AWS_REGION:-us-east-1}"
    ENV_ARGS+=(--env "AWS_REGION=${AWS_REGION_EFF}")
    [[ -n "${BEDROCK_REGIONS:-}" ]] && ENV_ARGS+=(--env "BEDROCK_REGIONS=${BEDROCK_REGIONS}")
    ;;

  custom)
    # An arbitrary endpoint: its hostname is the only thing allowlisted, and it
    # is resolved on the HOST before the guest boots, so nothing inside can
    # repoint the harness at somewhere else and reach it.
    [[ -n "${CUSTOM_BASE_URL:-}" ]] || missing_key "CUSTOM_BASE_URL"
    ENV_ARGS+=(--env "CUSTOM_BASE_URL=${CUSTOM_BASE_URL}")
    [[ -n "${CUSTOM_API_KEY:-}" ]] && ENV_ARGS+=(--env "CUSTOM_API_KEY=${CUSTOM_API_KEY}")
    ;;

  none) ;;  # deliberately keyless

  *)
    CRED_VAR=$(provider_cred_vars "$PROVIDER")
    if [[ -z "${!CRED_VAR:-}" ]]; then missing_key "$CRED_VAR"; fi
    ENV_ARGS+=(--env "${CRED_VAR}=${!CRED_VAR}")
    ;;
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
# State is keyed by harness AND provider: a claude:anthropic session and a
# claude:bedrock session get separate config, so provider-specific settings can't
# leak across sessions or fight each other on startup.
if [[ "$HARNESS" != "none" ]]; then
  STATE="${STATE_ROOT}/state/${HARNESS}-${PROVIDER}"
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
    pi)
      MOUNTS+=(--volume "${STATE}:/home/agent/.pi")
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
      [[ -n "${MODEL:-}" ]] && set -- "$@" --model "${MODEL}"
      ;;
    codex)
      set -- codex   # approvals off via config.toml
      [[ -n "${MODEL:-}" ]] && set -- "$@" -m "${MODEL}"
      ;;
    opencode)
      set -- opencode   # permissions allowed via opencode.json
      [[ -n "${MODEL:-}" ]] && set -- "$@" --model "${MODEL}"
      ;;
    pi)
      set -- pi   # provider/model pinned in settings.json by setup-harness.sh
      ;;
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
