#!/bin/bash
# Usage:
#   ./run.sh [OPTIONS] [REPO] [COMMAND...]
#
# Options:
#   --with-credentials    Mount ~/.claude/.credentials.json (subscription users,
#                         avoids `claude login` each session — see README for risks)
#
# Examples:
#   ./run.sh                                          # mount cwd, drop to bash
#   ./run.sh ~/projects/myrepo                        # mount repo, drop to bash
#   ./run.sh --with-credentials ~/projects/myrepo     # same, with persistent login
#   ./run.sh ~/projects/myrepo claude --dangerously-skip-permissions
set -euo pipefail

WITH_CREDENTIALS=false

# Parse options
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --with-credentials) WITH_CREDENTIALS=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

REPO="${1:-$(pwd)}"
shift || true   # remaining args become the container command (defaults to bash)

CLAUDE_DIR="${HOME}/.claude"

DOCKER_ARGS=(
  -it --rm
  --cap-add NET_ADMIN
  -v "$REPO":/workspace
  # Settings and skills — read-only so the container can't tamper with them
  -v "${CLAUDE_DIR}/settings.json":/root/.claude/settings.json:ro
  -v "${CLAUDE_DIR}/skills":/root/.claude/skills:ro
  -v "${CLAUDE_DIR}/plugins":/root/.claude/plugins:ro
)

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  DOCKER_ARGS+=(-e ANTHROPIC_API_KEY)
elif [[ "$WITH_CREDENTIALS" == true ]]; then
  if [[ ! -f "${CLAUDE_DIR}/.credentials.json" ]]; then
    echo "ERROR: ${CLAUDE_DIR}/.credentials.json not found. Run 'claude login' on the host first." >&2
    exit 1
  fi
  echo "NOTE: Mounting credentials. Only use with trusted repositories." >&2
  DOCKER_ARGS+=(-v "${CLAUDE_DIR}/.credentials.json":/root/.claude/.credentials.json:ro)
else
  echo "NOTE: ANTHROPIC_API_KEY not set. Run 'claude login' inside the container, or use --with-credentials." >&2
fi

docker run "${DOCKER_ARGS[@]}" claude-go-dev "$@"
