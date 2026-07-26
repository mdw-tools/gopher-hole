#!/usr/bin/env bash
# Configure the selected harness, in-guest, at every session start.
#
# The theme: turn the harness's OWN sandbox and approval prompts off. The VM
# plus a single mounted directory is the boundary, and the whole point of that
# boundary is that you can stop clicking "allow". Two of these tools also ship
# Linux sandboxes (seccomp/Landlock) that may not work in the guest kernel;
# disabling them avoids a failure mode that buys nothing here.
#
# Config lives in a per-harness state dir mounted from ~/.gopher-hole/state, so
# these files persist across sessions and never touch the host's real config.
set -euo pipefail

HARNESS="${GOPHER_HARNESS:-none}"

case "$HARNESS" in
  claude)
    # Auto-approval is a launch flag (--dangerously-skip-permissions), applied
    # by run.sh; nothing to write here beyond ensuring the dir exists.
    mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    ;;

  codex)
    # Written once. Codex's own sandbox uses Landlock/seccomp, which the guest
    # kernel may not provide; danger-full-access defers to the VM boundary.
    CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
    mkdir -p "$CODEX_DIR"
    if [[ ! -f "${CODEX_DIR}/config.toml" ]]; then
      cat > "${CODEX_DIR}/config.toml" <<'EOF'
# Written by gopher-hole attempt-005 on first run. Safe to edit — it will not
# be overwritten. The VM is the sandbox, so codex's own one is turned off.
approval_policy = "never"
sandbox_mode = "danger-full-access"
EOF
      echo "setup-harness: wrote ${CODEX_DIR}/config.toml"
    fi
    ;;

  opencode)
    # Merged, so hand edits to other keys survive.
    OC_DIR="${HOME}/.config/opencode"
    mkdir -p "$OC_DIR"
    CONFIG="${OC_DIR}/opencode.json"
    [[ -f "$CONFIG" ]] || echo '{}' > "$CONFIG"
    jq '. + {permission: {edit: "allow", bash: "allow", webfetch: "allow"}}' \
      "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
    ;;

  amp)
    # Amp's auto-approval setting name is not pinned down here; it runs at its
    # defaults and will prompt. See README "Per-harness notes".
    mkdir -p "${HOME}/.config/amp"
    ;;

  none)
    ;;

  *)
    echo "setup-harness: unknown harness '${HARNESS}'" >&2
    exit 1
    ;;
esac
