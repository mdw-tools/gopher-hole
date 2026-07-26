#!/usr/bin/env bash
# Configure the selected harness × provider pair, in-guest, at every session start.
#
# Two themes:
#
#   1. Turn the harness's OWN sandbox and approval prompts off. The VM plus a
#      single mounted directory is the boundary, and the point of that boundary
#      is that you can stop clicking "allow". Two of these tools also ship Linux
#      sandboxes (seccomp/Landlock) that may not work in the guest kernel;
#      disabling them avoids a failure mode that buys nothing here.
#
#   2. Point the harness at the chosen provider. Each expresses this differently
#      — env vars for claude, config.toml for codex, JSON for opencode and pi —
#      which is exactly why it lives in one place instead of being spread across
#      run.sh. Every key and identifier used below was read out of the pinned
#      binaries; see README "Provider matrix".
#
# Config lives in a per-(harness,provider) state dir mounted from
# ~/.gopher-hole/state, so these files persist across sessions and never touch
# the host's real config.
set -euo pipefail

HARNESS="${GOPHER_HARNESS:-none}"
PROVIDER="${GOPHER_PROVIDER:-none}"

# Provider env vars are accumulated into a file that entrypoint.sh sources
# BEFORE launching the session command — this script is a child process, so a
# plain `export` here would die with it and the harness would never see
# CLAUDE_CODE_USE_BEDROCK at all. Truncated once, appended thereafter.
PROVIDER_ENV=/home/agent/.gopher-provider-env
: > "$PROVIDER_ENV"

provider_env() {
  local kv
  for kv in "$@"; do
    printf 'export %s\n' "$kv" >> "$PROVIDER_ENV"
  done
}

case "$HARNESS" in
  claude)
    mkdir -p "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    case "$PROVIDER" in
      anthropic) ;;  # the default; nothing to set
      bedrock)
        # CLAUDE_CODE_USE_BEDROCK is claude's own Bedrock switch; it then uses
        # AWS_BEARER_TOKEN_BEDROCK or the standard credential chain.
        provider_env "CLAUDE_CODE_USE_BEDROCK=1" \
                     "AWS_REGION=${AWS_REGION:-us-east-1}"
        ;;
      custom)
        provider_env "ANTHROPIC_BASE_URL=${CUSTOM_BASE_URL}"
        [[ -n "${CUSTOM_API_KEY:-}" ]] \
          && provider_env "ANTHROPIC_API_KEY=${CUSTOM_API_KEY}"
        ;;
    esac
    ;;

  codex)
    CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
    mkdir -p "$CODEX_DIR"
    if [[ ! -f "${CODEX_DIR}/config.toml" ]]; then
      # Written once. Safe to edit afterwards — never overwritten.
      cat > "${CODEX_DIR}/config.toml" <<'EOF'
# Written by gopher-hole attempt-005 on first run. Safe to edit — it will not
# be overwritten. The VM is the sandbox, so codex's own one is turned off.
approval_policy = "never"
sandbox_mode = "danger-full-access"
EOF
      if [[ "$PROVIDER" == "custom" ]]; then
        # model_providers + base_url + wire_api are codex's generic custom-endpoint
        # mechanism. This is also the supported route to Bedrock: put an
        # OpenAI-compatible gateway in front of it and point here.
        cat >> "${CODEX_DIR}/config.toml" <<EOF

model_provider = "gopher_custom"

[model_providers.gopher_custom]
name = "gopher-hole custom endpoint"
base_url = "${CUSTOM_BASE_URL}"
wire_api = "chat"
env_key = "CUSTOM_API_KEY"
EOF
      fi
      echo "setup-harness: wrote ${CODEX_DIR}/config.toml"
    fi
    ;;

  opencode)
    OC_DIR="${HOME}/.config/opencode"
    mkdir -p "$OC_DIR"
    CONFIG="${OC_DIR}/opencode.json"
    [[ -f "$CONFIG" ]] || echo '{}' > "$CONFIG"
    # Merged, so hand edits to other keys survive.
    jq '. + {permission: {edit: "allow", bash: "allow", webfetch: "allow"}}' \
      "$CONFIG" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "$CONFIG"
    if [[ "$PROVIDER" == "bedrock" ]]; then
      provider_env "AWS_REGION=${AWS_REGION:-us-east-1}"
    fi
    # opencode resolves models via models.dev using provider ids; MODEL is
    # expected in that catalog's "provider/model" form, e.g.
    # amazon-bedrock/anthropic.claude-sonnet-4-20250514-v1:0
    if [[ -n "${MODEL:-}" ]]; then
      jq --arg m "$MODEL" '. + {model: $m}' "$CONFIG" > "${CONFIG}.tmp" \
        && mv "${CONFIG}.tmp" "$CONFIG"
    fi
    ;;

  pi)
    # pi's api identifiers come from its own Api union (read out of pi-ai):
    # anthropic-messages | openai-completions | openai-responses |
    # bedrock-converse-stream | google-vertex | ...
    AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
    mkdir -p "$AGENT_DIR"
    case "$PROVIDER" in
      anthropic) PI_API="anthropic-messages"; PI_BASE="https://api.anthropic.com/v1"; PI_KEY="${ANTHROPIC_API_KEY:-}" ;;
      openai)    PI_API="openai-completions";  PI_BASE="https://api.openai.com/v1";   PI_KEY="${OPENAI_API_KEY:-}" ;;
      bedrock)   PI_API="bedrock-converse-stream"; PI_BASE=""; PI_KEY="${AWS_BEARER_TOKEN_BEDROCK:-}"
                 provider_env "AWS_REGION=${AWS_REGION:-us-east-1}" ;;
      custom)    PI_API="openai-completions";  PI_BASE="${CUSTOM_BASE_URL}";          PI_KEY="${CUSTOM_API_KEY:-none}" ;;
    esac
    if [[ -n "${MODEL:-}" ]]; then
      # Only generate a provider entry when a model is named; without one pi has
      # nothing to list, and its built-in provider defaults are a better guess
      # than anything invented here.
      jq -n --arg api "$PI_API" --arg base "$PI_BASE" --arg key "$PI_KEY" \
            --arg model "$MODEL" '
        { providers: { gopher: (
            { api: $api, apiKey: (if $key == "" then "none" else $key end),
              models: [ { id: $model, contextWindow: 200000, maxTokens: 32000 } ] }
            + (if $base == "" then {} else { baseUrl: $base } end) ) } }' \
        > "${AGENT_DIR}/models.json"
      SETTINGS="${AGENT_DIR}/settings.json"
      [[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
      jq --arg model "$MODEL" \
        '. + {defaultProvider: "gopher", defaultModel: $model}' \
        "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
      echo "setup-harness: pi → ${PI_API} model ${MODEL}"
    else
      echo "setup-harness: pi using its built-in ${PROVIDER} provider (set MODEL to pin one)" >&2
    fi
    ;;

  amp)
    # Amp routes models server-side: no provider choice, and its auto-approval
    # setting is not pinned down here, so it runs at defaults and will prompt.
    mkdir -p "${HOME}/.config/amp"
    ;;

  none) ;;

  *)
    echo "setup-harness: unknown harness '${HARNESS}'" >&2
    exit 1
    ;;
esac
