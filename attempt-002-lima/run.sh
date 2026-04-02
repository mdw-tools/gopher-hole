#!/bin/bash
# Launch a Claude Code session inside the Lima VM.
#
# Usage:
#   ./run.sh [PROJECT_DIR] [COMMAND...]
#
# Examples:
#   ./run.sh                                    # cwd, launch claude
#   ./run.sh ~/src/myproject                    # specific dir, launch claude
#   ./run.sh ~/src/myproject bash               # specific dir, drop to bash
set -euo pipefail

VM_NAME="gopher-hole"
PROJECT_DIR="${1:-$(pwd)}"
shift || true

# Default command: claude with dangerously-skip-permissions
if [[ $# -eq 0 ]]; then
  set -- claude --dangerously-skip-permissions
fi

# Ensure the VM is running
STATUS=$(limactl list --json | jq -r "select(.name == \"${VM_NAME}\") | .status")
if [[ "$STATUS" != "Running" ]]; then
  echo "VM '${VM_NAME}' is not running (status: ${STATUS:-not found})."
  echo "Start it with: limactl start ${VM_NAME}"
  exit 1
fi

# Resolve to absolute path
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)

# The mount point inside the VM mirrors the host path for ~/src.
# Lima with VirtioFS mounts ~/src -> /Users/<user>/src (same path).
VM_WORKDIR="$PROJECT_DIR"

# Build env args
ENV_ARGS=()
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  ENV_ARGS+=(--env "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
else
  echo "NOTE: ANTHROPIC_API_KEY not set. You'll need to run 'claude login' inside the VM." >&2
fi

exec limactl shell "${ENV_ARGS[@]}" --workdir "$VM_WORKDIR" "$VM_NAME" "$@"
