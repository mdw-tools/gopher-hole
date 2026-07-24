#!/bin/bash
# Launch a pi session inside a disposable apple/container VM, sharing only
# the project directory (mounted at its host absolute path).
#
# Usage:
#   ./run.sh [PROJECT_DIR] [COMMAND...]
#
# Examples:
#   ./run.sh                              # cwd, drop to bash
#   ./run.sh ~/src/myproject              # specific dir, drop to bash
#   ./run.sh ~/src/myproject pi           # specific dir, launch pi directly
#   ./run.sh ~/src/myproject hunk diff    # review agent changes in the TUI
#
# Environment (optional):
#   LMSTUDIO_PORT           host port LM Studio serves on (default 1234)
#   LMSTUDIO_DEFAULT_MODEL  model id pi should default to
#   EGRESS_ALLOW_VCS=1      also allow in-guest git/go get (default: LM Studio
#                           only — commits and fetches happen on the host)
set -euo pipefail

IMAGE="gopher-hole"
PI_STATE_DIR="${HOME}/.pi-gopher-hole"

PROJECT_DIR="${1:-$(pwd)}"
shift || true

# Default command: an interactive shell (launch pi from there when ready)
if [[ $# -eq 0 ]]; then
  set -- bash
fi

# Resolve symlinks so the host path and the in-guest mount agree exactly
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd -P)
mkdir -p "${PI_STATE_DIR}"

# Forward git identity as env vars — no ~/.gitconfig enters the guest
ENV_ARGS=()
GIT_NAME=$(git config --global user.name 2>/dev/null || true)
GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
[[ -n "$GIT_NAME" ]] && ENV_ARGS+=(--env "GIT_AUTHOR_NAME=${GIT_NAME}" --env "GIT_COMMITTER_NAME=${GIT_NAME}")
[[ -n "$GIT_EMAIL" ]] && ENV_ARGS+=(--env "GIT_AUTHOR_EMAIL=${GIT_EMAIL}" --env "GIT_COMMITTER_EMAIL=${GIT_EMAIL}")
[[ -n "${LMSTUDIO_PORT:-}" ]] && ENV_ARGS+=(--env "LMSTUDIO_PORT=${LMSTUDIO_PORT}")
[[ -n "${LMSTUDIO_DEFAULT_MODEL:-}" ]] && ENV_ARGS+=(--env "LMSTUDIO_DEFAULT_MODEL=${LMSTUDIO_DEFAULT_MODEL}")
[[ -n "${EGRESS_ALLOW_VCS:-}" ]] && ENV_ARGS+=(--env "EGRESS_ALLOW_VCS=${EGRESS_ALLOW_VCS}")

# Mount this repo's .git read-only: the agent edits the working tree freely,
# but cannot write commits, config, hooks, or filters — closing the vector
# where poisoned git metadata would execute when you run git on the host.
# Commits and pushes happen on the host. Only a single top-level .git dir is
# protected; see README for the multi-repo case.
GIT_MOUNT=()
GIT_DIR_PATH="${PROJECT_DIR}/.git"
if [[ -d "$GIT_DIR_PATH" ]]; then
  GIT_MOUNT+=(--volume "${GIT_DIR_PATH}:${GIT_DIR_PATH}:ro")
elif [[ -e "$GIT_DIR_PATH" ]]; then
  echo "note: ${GIT_DIR_PATH} is a file (worktree/submodule) — read-only .git protection skipped." >&2
fi

# Allocate a TTY only when we have one (verify.sh runs without)
TTY_ARGS=()
[[ -t 0 ]] && TTY_ARGS+=(-it)

# CAP_NET_ADMIN lets the entrypoint's root stage install the nftables egress
# allowlist in the guest's own kernel; setpriv strips it before the agent runs
exec container run --rm \
  --cap-add CAP_NET_ADMIN \
  ${TTY_ARGS[@]+"${TTY_ARGS[@]}"} \
  --volume "${PROJECT_DIR}:${PROJECT_DIR}" \
  ${GIT_MOUNT[@]+"${GIT_MOUNT[@]}"} \
  --volume "${PI_STATE_DIR}:/home/agent/.pi" \
  --workdir "${PROJECT_DIR}" \
  ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  "${IMAGE}" "$@"
