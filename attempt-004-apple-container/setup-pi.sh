#!/usr/bin/env bash
# Generate pi's provider config from the host's LM Studio server, reached via
# the vmnet gateway. Runs at every container start (see entrypoint.sh) so the
# model list always matches what LM Studio currently has loaded.
#
# Environment overrides:
#   LMSTUDIO_PORT           host port LM Studio serves on (default 1234)
#   LMSTUDIO_DEFAULT_MODEL  model id to pin as pi's default (default: first listed)
set -euo pipefail

AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PORT="${LMSTUDIO_PORT:-1234}"

GW=$(ip route | awk '/default/ {print $3; exit}')
[[ -n "$GW" ]] || { echo "setup-pi: no default gateway found" >&2; exit 1; }

MODELS_JSON=$(curl -fsS --max-time 5 "http://${GW}:${PORT}/v1/models")

mkdir -p "$AGENT_DIR"

# One provider entry per model LM Studio has loaded (embedding models excluded)
jq --arg baseUrl "http://${GW}:${PORT}/v1" '
  {
    providers: {
      lmstudio: {
        baseUrl: $baseUrl,
        api: "openai-completions",
        apiKey: "lmstudio",
        models: [ .data[]
                  | select(.id | test("embed") | not)
                  | { id: .id, contextWindow: 128000, maxTokens: 32000 } ]
      }
    }
  }' <<<"$MODELS_JSON" > "$AGENT_DIR/models.json"

DEFAULT_MODEL="${LMSTUDIO_DEFAULT_MODEL:-$(jq -r '.providers.lmstudio.models[0].id' "$AGENT_DIR/models.json")}"

# Pin provider/model defaults without clobbering other persisted settings
SETTINGS="$AGENT_DIR/settings.json"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
jq --arg model "$DEFAULT_MODEL" \
  '. + {defaultProvider: "lmstudio", defaultModel: $model}' \
  "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo "setup-pi: lmstudio at http://${GW}:${PORT}/v1 — default model: ${DEFAULT_MODEL}"
