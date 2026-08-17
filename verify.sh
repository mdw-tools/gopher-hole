#!/usr/bin/env bash
# Smoke tests for gopher-hole.
#
# The egress and credential sections are the interesting ones: they assert the
# claims the README makes, including the negative ones (a claude session cannot
# reach OpenAI; the agent user has no DNS at all).
#
# Usage:
#   ./verify.sh                    # run every section
#   ./verify.sh image egress       # run named sections only
set -uo pipefail

IMAGE="gopher-hole"
STATE_ROOT="${GOPHER_STATE_DIR:-${HOME}/.gopher-hole}"

# shellcheck source=providers.sh
. "$(cd "$(dirname "$0")" && pwd -P)/providers.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0

section() { echo -e "${CYAN}--- $*${NC}"; }
ok()      { PASS=$((PASS + 1)); echo -e "${GREEN}  ✓ $*${NC}"; }
bad()     { FAIL=$((FAIL + 1)); echo -e "${RED}  ✗ $*${NC}"; }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

check_fails() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
}

check_out() {
  local desc="$1" expected="$2"; shift 2
  local output
  output=$("$@" 2>&1)
  if [[ "$output" == *"$expected"* ]]; then ok "$desc"; else bad "$desc (got: ${output:0:140})"; fi
}

# guest <harness> <command...> — a session without the launcher, so the egress tests
# don't depend on having API keys set. CAP_NET_ADMIN mirrors the launcher.
guest() {
  local harness="$1"; shift
  container run --rm --cap-add CAP_NET_ADMIN \
    --env "GOPHER_HARNESS=${harness}" \
    --env "GOPHER_PROVIDER=$(harness_default_provider "$harness")" \
    "${IMAGE}" "$@"
}

# summary <harness> <opencode-mode> <shell-script> — run a session and echo only
# its end-of-session egress summary. Asserting against the summary alone matters:
# the firewall's startup line names the same hostnames, so matching the whole
# output would let a test pass on the wrong evidence.
summary() {
  local harness="$1" provider="$2" script="$3"
  container run --rm --cap-add CAP_NET_ADMIN \
    --env "GOPHER_HARNESS=${harness}" --env "GOPHER_PROVIDER=${provider}" \
    --env "AWS_REGION=us-east-1" \
    "${IMAGE}" bash -c "$script" 2>&1 | sed -n '/--- egress summary/,$p'
}

verify_image() {
  section "image: toolchain and all four harnesses baked into '${IMAGE}'"
  check "image '${IMAGE}' exists" container image inspect "${IMAGE}"
  check "claude available"   guest none claude --version
  check "codex available"    guest none codex --version
  check "opencode available" guest none opencode --version
  check "amp available"      guest none amp --version
  check "pi available"       guest none pi --version
  check "hunk available"     guest none hunk --version
  check "tinyproxy present"  guest none tinyproxy -v
  check "git available"      guest none git --version
  check "node available"     guest none node --version
  check "make available"     guest none make --version
  check "gcc available"      guest none gcc --version
  check "jq available"       guest none jq --version
  check_out "go 1.26 on PATH" "go1.26" guest none go version
  check_out "runs as non-root 'agent' user" "USER=agent" \
    guest none bash -c 'echo "USER=$(id -un)"'
}

verify_egress() {
  section "egress: proxy-only, hostname-filtered, per-harness"

  # The model endpoint is reachable: 401 (no key) proves we got a TLS response
  # from the real host rather than a proxy refusal. Per-provider reachability and
  # cross-provider isolation are covered exhaustively by the 'matrix' section.
  check_out "claude session reaches api.anthropic.com" "401" \
    guest claude curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    https://api.anthropic.com/v1/models

  # Arbitrary hosts refused regardless of harness
  check_fails "example.com refused" \
    guest claude curl -fsS --max-time 20 https://example.com
  check_fails "lookalike host refused (anchored filter)" \
    guest claude curl -fsS --max-time 20 https://api.anthropic.com.example.com

  # The agent user has no DNS: only tinyproxy resolves, so DNS-query
  # exfiltration stays closed even though the model API is reachable.
  check_fails "agent user cannot resolve DNS" \
    guest claude getent hosts api.anthropic.com
  check_fails "agent user cannot connect directly (bypassing the proxy)" \
    guest claude env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy \
    curl -fsS --max-time 20 https://api.anthropic.com/v1/models

  # The agent cannot see or change the ruleset that confines it
  check_fails "agent cannot read the nftables ruleset" \
    guest claude nft list ruleset
  check_fails "agent cannot edit the proxy allowlist" \
    guest claude bash -c 'echo "^example\.com$" >> /etc/tinyproxy/gopher-allow.txt'

  # Toolchain hosts are allowed in every posture, so in-guest builds work
  check "go module proxy reachable" \
    guest none bash -c 'mkdir -p /tmp/s && cd /tmp/s && go mod init s >/dev/null 2>&1 && go get golang.org/x/text@latest'

  # Opt-in additions
  check "EGRESS_EXTRA_HOSTS widens the allowlist" \
    container run --rm --cap-add CAP_NET_ADMIN \
      --env GOPHER_HARNESS=none --env EGRESS_EXTRA_HOSTS=example.com \
      "${IMAGE}" curl -fsS --max-time 20 https://example.com

}

verify_cli() {
  section "cli: --dry-run, subcommands, and credential hygiene"
  local dir out
  dir=$(cd "$(mktemp -d)" && pwd -P)
  check_out "--dry-run prints the container invocation" "container run" \
    env ANTHROPIC_API_KEY=decoy-secret-value ./gopher-hole --dry-run pi:anthropic "$dir"
  out=$(env ANTHROPIC_API_KEY=decoy-secret-value ./gopher-hole --dry-run pi:anthropic "$dir" 2>&1)
  if [[ "$out" == *"container run"* && "$out" != *decoy-secret-value* ]]; then
    ok "credential values never printed"
  else bad "credential values never printed (got: ${out:0:120})"; fi
  check_out "review resolves to hunk diff" "hunk diff" \
    ./gopher-hole --dry-run review "$dir"
  check_out "review runs keyless (harness none)" "GOPHER_HARNESS=none" \
    ./gopher-hole --dry-run review "$dir"
  check_out "shell resolves to a keyless bash session" "GOPHER_HARNESS=none" \
    ./gopher-hole --dry-run shell "$dir"
  check_fails "unknown harness rejected" ./gopher-hole --dry-run bogus "$dir"
  rm -rf "$dir"
}

verify_matrix() {
  section "matrix: pairs, postures, and credentials agree with providers.sh"
  # Table shape first: the lmstudio provider and the posture function
  check "pi supports lmstudio" harness_supports pi lmstudio
  check_out "lmstudio posture is local"    "local"  provider_posture lmstudio
  check_out "none posture is hosted (keyless, toolchain via proxy)" "hosted" provider_posture none
  check_out "anthropic posture is hosted"  "hosted" provider_posture anthropic
  check_out "openai posture is hosted"     "hosted" provider_posture openai
  check_out "zen posture is hosted"        "hosted" provider_posture zen
  check_out "amp posture is hosted"        "hosted" provider_posture amp
  check_out "bedrock posture is hosted"    "hosted" provider_posture bedrock
  check_out "custom posture is hosted"     "hosted" provider_posture custom
  local cred_out
  if cred_out=$(provider_cred_vars lmstudio 2>/dev/null) && [[ -z "$cred_out" ]]; then
    ok "lmstudio needs no credential"
  else
    bad "lmstudio needs no credential (got: '${cred_out:-<error>}')"
  fi

  section "matrix: every valid hosted pair gets its own provider's host and no other's"
  # Table-driven on purpose. Hand-written per-combo tests would drift from
  # providers.sh, and a stale entry there is the failure mode that matters: a
  # session that carries one provider's key while the firewall opens another's
  # would still WORK, so nothing would draw attention to it.
  local harness provider host others other_host reached refused out ok_all
  for harness in $(all_harnesses); do
    for provider in $(harness_providers "$harness"); do
      [[ "$provider" == "none" || "$provider" == "custom" ]] && continue
      # Local-posture providers have no proxy and no egress summary to probe;
      # the firewall_local section covers them.
      [[ "$(provider_posture "$provider" 2>/dev/null)" == "local" ]] && continue

      host=$(AWS_REGION=us-east-1 provider_model_hosts "$provider" | awk '{print $1}')

      # Probe its own host plus every OTHER provider's host in one session.
      # Deliberately including providers this harness *does* support elsewhere:
      # the isolation that matters is per-session, so opencode:zen must not reach
      # api.anthropic.com even though opencode:anthropic legitimately would.
      others=""
      for other in anthropic openai zen amp bedrock; do
        [[ "$other" == "$provider" ]] && continue
        other_host=$(AWS_REGION=us-east-1 provider_model_hosts "$other" | awk '{print $1}')
        others="${others} ${other_host}"
      done

      local script="curl -s -o /dev/null --max-time 20 https://${host}/ || true"
      for other_host in $others; do
        script="${script}; curl -s -o /dev/null --max-time 20 https://${other_host}/ || true"
      done

      out=$(container run --rm --cap-add CAP_NET_ADMIN \
              --env "GOPHER_HARNESS=${harness}" --env "GOPHER_PROVIDER=${provider}" \
              --env "AWS_REGION=us-east-1" \
              "${IMAGE}" bash -c "$script" 2>&1 | sed -n '/--- egress summary/,$p')
      reached=$(sed -n '/^reached:/,/^refused/p' <<<"$out")
      refused=$(sed -n '/^refused/,$p' <<<"$out")

      if [[ "$reached" == *"$host"* ]]; then ok "${harness}:${provider} reaches ${host}"
      else bad "${harness}:${provider} reaches ${host} (reached: ${reached:0:100})"; fi

      ok_all=1
      for other_host in $others; do
        if [[ "$reached" == *"$other_host"* ]]; then
          bad "${harness}:${provider} must NOT reach ${other_host}"
          ok_all=0
        fi
      done
      [[ $ok_all -eq 1 && -n "$others" ]] \
        && ok "${harness}:${provider} refuses all other providers' hosts"
    done
  done
}

verify_creds_matrix() {
  section "credential matrix: exactly one provider's key per session"
  # Decoy values for EVERY credential the matrix knows, so each pair can be
  # checked for carrying its own and only its own — no real keys needed.
  local dir harness provider expect var out decoys=()
  dir=$(cd "$(mktemp -d)" && pwd -P)
  for var in $(all_provider_cred_vars); do
    decoys+=("${var}=decoy-${var}")
  done

  for harness in $(all_harnesses); do
    for provider in $(harness_providers "$harness"); do
      [[ "$provider" == "none" || "$provider" == "custom" ]] && continue

      # Ask the guest for its env var NAMES only and filter here, where the
      # credential list lives — no quoting gymnastics inside bash -c, and no
      # chance of a decoy value landing in the test output.
      out=$(env "${decoys[@]}" AWS_REGION=us-east-1 \
              ./gopher-hole "${harness}:${provider}" "$dir" \
              bash -c 'env | cut -d= -f1' 2>/dev/null | sort -u)

      # A local-posture pair must launch with NO credential at all, even with
      # every key sitting in the host environment.
      if [[ "$(provider_posture "$provider")" == "local" ]]; then
        if grep -qx "GOPHER_PROVIDER" <<<"$out"; then ok "${harness}:${provider} session launches keyless"
        else bad "${harness}:${provider} session launches keyless (no session output)"; fi
        local leaked_local=""
        for var in $(all_provider_cred_vars); do
          grep -qx "$var" <<<"$out" && leaked_local="${leaked_local} ${var}"
        done
        if [[ -z "$leaked_local" ]]; then ok "${harness}:${provider} carries no credential"
        else bad "${harness}:${provider} leaked:${leaked_local}"; fi
        continue
      fi

      case "$provider" in
        bedrock) expect="AWS_BEARER_TOKEN_BEDROCK" ;;
        *)       expect=$(provider_cred_vars "$provider") ;;
      esac

      if grep -qx "$expect" <<<"$out"; then ok "${harness}:${provider} carries ${expect}"
      else bad "${harness}:${provider} carries ${expect} (absent)"; fi

      # Every other provider's credential must be absent despite being set on the host
      local leaked=""
      for var in $(all_provider_cred_vars); do
        [[ "$var" == "$expect" ]] && continue
        # bedrock legitimately needs AWS_REGION and may carry session creds
        [[ "$provider" == "bedrock" && "$var" == AWS_* ]] && continue
        grep -qx "$var" <<<"$out" && leaked="${leaked} ${var}"
      done
      if [[ -z "$leaked" ]]; then ok "${harness}:${provider} leaks no other credential"
      else bad "${harness}:${provider} leaked:${leaked}"; fi
    done
  done
  rm -rf "$dir"
}

verify_pairs() {
  section "pair validation: invalid combinations are refused, not ignored"
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  check_fails "amp:bedrock rejected"       ./gopher-hole amp:bedrock "$dir" true
  check_fails "codex:anthropic rejected"   ./gopher-hole codex:anthropic "$dir" true
  check_fails "claude:openai rejected"     ./gopher-hole claude:openai "$dir" true
  check_fails "codex:bedrock rejected (no verified config path)" \
    ./gopher-hole codex:bedrock "$dir" true
  check_fails "unknown provider rejected"  ./gopher-hole claude:bogus "$dir" true
  check_fails "unknown harness rejected"   ./gopher-hole bogus:anthropic "$dir" true
  check_out "claude defaults to anthropic" "GOPHER_PROVIDER=anthropic" \
    env ANTHROPIC_API_KEY=decoy ./gopher-hole claude "$dir" \
    bash -c 'echo "GOPHER_PROVIDER=${GOPHER_PROVIDER}"'
  check_out "opencode defaults to zen" "GOPHER_PROVIDER=zen" \
    env OPENCODE_API_KEY=decoy ./gopher-hole opencode "$dir" \
    bash -c 'echo "GOPHER_PROVIDER=${GOPHER_PROVIDER}"'
  check_fails "bedrock without any AWS credential refused" \
    env -u AWS_BEARER_TOKEN_BEDROCK -u AWS_ACCESS_KEY_ID \
    ./gopher-hole claude:bedrock "$dir" true
  check_fails "custom without CUSTOM_BASE_URL refused" \
    env -u CUSTOM_BASE_URL ./gopher-hole claude:custom "$dir" true
  rm -rf "$dir"
}

verify_wiring() {
  section "provider wiring: harness actually pointed at the chosen provider"
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  # claude+bedrock must set claude's own Bedrock switch in the session env
  check_out "claude:bedrock sets CLAUDE_CODE_USE_BEDROCK" "USE_BEDROCK=1" \
    env AWS_BEARER_TOKEN_BEDROCK=decoy AWS_REGION=us-east-1 \
    ./gopher-hole claude:bedrock "$dir" \
    bash -c 'echo "USE_BEDROCK=${CLAUDE_CODE_USE_BEDROCK:-unset}"'
  check_out "claude:anthropic leaves it unset" "USE_BEDROCK=unset" \
    env ANTHROPIC_API_KEY=decoy ./gopher-hole claude:anthropic "$dir" \
    bash -c 'echo "USE_BEDROCK=${CLAUDE_CODE_USE_BEDROCK:-unset}"'
  # custom endpoint: base url reaches the harness, and only its host is allowed
  check_out "claude:custom sets ANTHROPIC_BASE_URL" "example.org" \
    env CUSTOM_BASE_URL=https://gw.example.org/v1 CUSTOM_API_KEY=decoy \
    ./gopher-hole claude:custom "$dir" bash -c 'echo "${ANTHROPIC_BASE_URL:-unset}"'
  check_out "codex:custom writes a model_providers block" "gopher_custom" \
    env CUSTOM_BASE_URL=https://gw.example.org/v1 CUSTOM_API_KEY=decoy \
    ./gopher-hole codex:custom "$dir" cat /home/agent/.codex/config.toml
  # pi is new here: prove it launched and got its provider config
  check_out "pi:anthropic generates a models.json for a pinned MODEL" "anthropic-messages" \
    env ANTHROPIC_API_KEY=decoy MODEL=claude-sonnet-4-5 \
    ./gopher-hole pi:anthropic "$dir" cat /home/agent/.pi/agent/models.json
  check_out "pi:bedrock uses bedrock-converse-stream" "bedrock-converse-stream" \
    env AWS_BEARER_TOKEN_BEDROCK=decoy MODEL=anthropic.claude-sonnet-4-v1:0 \
    ./gopher-hole pi:bedrock "$dir" cat /home/agent/.pi/agent/models.json
  rm -rf "$dir"
}

verify_firewall_local() {
  section "firewall_local: total lockdown — LM Studio only, no proxy, no DNS"
  local run=(container run --rm --cap-add CAP_NET_ADMIN
    --env GOPHER_HARNESS=pi --env GOPHER_PROVIDER=lmstudio "${IMAGE}")
  local lm_probe="${LMSTUDIO_HOST:-localhost}" lm_port="${LMSTUDIO_PORT:-1234}"

  # Positive reachability needs a live LM Studio; skip cleanly when absent so
  # the suite still runs on machines without it. The negative claims below are
  # the load-bearing ones and never skip.
  if curl -fsS --max-time 2 "http://${lm_probe}:${lm_port}/v1/models" >/dev/null 2>&1; then
    if [[ -n "${LMSTUDIO_HOST:-}" ]]; then
      check "LM Studio via LMSTUDIO_HOST reachable" \
        container run --rm --cap-add CAP_NET_ADMIN \
          --env GOPHER_HARNESS=pi --env GOPHER_PROVIDER=lmstudio \
          --env LMSTUDIO_HOST="${LMSTUDIO_HOST}" --env LMSTUDIO_PORT="${lm_port}" \
          "${IMAGE}" \
          curl -fsS --max-time 10 "http://${LMSTUDIO_HOST}:${lm_port}/v1/models"
    else
      check "LM Studio via gateway reachable" "${run[@]}" bash -c \
        'curl -fsS --max-time 10 "http://$(ip route | awk "/default/ {print \$3; exit}"):'"${lm_port}"'/v1/models"'
    fi
  else
    ok "LM Studio positive check skipped (no server at ${lm_probe}:${lm_port})"
  fi

  check_fails "example.com blocked" \
    "${run[@]}" curl -fsS --max-time 10 https://example.com
  check_fails "go module proxy blocked (no toolchain egress)" \
    "${run[@]}" curl -fsS --max-time 10 https://proxy.golang.org
  check_fails "agent has no DNS" \
    "${run[@]}" getent hosts api.anthropic.com
  check_fails "tinyproxy not running" \
    "${run[@]}" bash -c 'grep -l tinyproxy /proc/[0-9]*/comm'
  check_out "proxy env vars cleared" "PROXY=unset" \
    "${run[@]}" bash -c 'echo "PROXY=${HTTPS_PROXY:-unset}"'
  check_fails "agent cannot read the nftables ruleset" \
    "${run[@]}" nft list ruleset

  # No proxy runs in this posture, so there is nothing to report on exit —
  # a summary here would be fabricated.
  local report_out
  report_out=$("${run[@]}" true 2>&1 | sed -n '/egress summary/p')
  if [[ -z "$report_out" ]]; then ok "no egress summary in a local-posture session"
  else bad "no egress summary in a local-posture session (got: ${report_out:0:100})"; fi

  # Remote LM Studio repoints the SINGLE allowed destination, so the gateway
  # itself goes dark (TEST-NET address — never answers).
  check_fails "gateway blocked when LMSTUDIO_HOST is set" \
    container run --rm --cap-add CAP_NET_ADMIN \
      --env GOPHER_HARNESS=pi --env GOPHER_PROVIDER=lmstudio \
      --env LMSTUDIO_HOST=203.0.113.7 "${IMAGE}" bash -c \
      'curl -fsS --max-time 5 "http://$(ip route | awk "/default/ {print \$3; exit}"):1234/v1/models"'
}

# Serve a minimal mock of LM Studio's native REST API (/api/v0/models) on the
# host, so the pi wiring is testable on machines without LM Studio. Binds all
# interfaces: the guest reaches the host via the vmnet gateway.
start_lmstudio_mock() {
  # >/dev/null keeps the backgrounded server from holding the caller's $()
  # pipe open forever.
  python3 - "$1" >/dev/null 2>&1 <<'EOF' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/v0/models':
            body = json.dumps({"data": [{"id": "mock-model", "type": "llm",
                                         "loaded_context_length": 4096}]}).encode()
        elif self.path == '/v1/models':
            body = json.dumps({"data": [{"id": "mock-model"}]}).encode()
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(('0.0.0.0', int(sys.argv[1])), H).serve_forever()
EOF
  echo $!
}

verify_pi_lmstudio() {
  section "pi_lmstudio: pi's model list generated from the LM Studio server"
  local lm_probe="${LMSTUDIO_HOST:-localhost}" lm_port="${LMSTUDIO_PORT:-1234}"
  local mock_pid="" dir out
  if ! curl -fsS --max-time 2 "http://${lm_probe}:${lm_port}/v1/models" >/dev/null 2>&1; then
    mock_pid=$(start_lmstudio_mock "$lm_port")
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      curl -fsS --max-time 1 "http://localhost:${lm_port}/v1/models" >/dev/null 2>&1 && break
      sleep 0.5
    done
  fi

  dir=$(cd "$(mktemp -d)" && pwd -P)
  out=$(./gopher-hole pi:lmstudio "$dir" bash -c \
    'cat /home/agent/.pi/agent/models.json /home/agent/.pi/agent/settings.json' 2>&1)

  if [[ "$out" == *'"lmstudio"'* ]]; then ok "models.json has an lmstudio provider"
  else bad "models.json has an lmstudio provider (got: ${out:0:140})"; fi
  if [[ "$out" == *'"contextWindow"'* ]]; then ok "models carry a context window"
  else bad "models carry a context window"; fi
  if [[ "$out" == *'"defaultProvider": "lmstudio"'* ]]; then ok "settings.json pins lmstudio as default"
  else bad "settings.json pins lmstudio as default"; fi
  if [[ -n "$mock_pid" ]]; then
    if [[ "$out" == *'"mock-model"'* && "$out" == *4096* ]]; then
      ok "model list and loaded_context_length match the server"
    else bad "model list and loaded_context_length match the server"; fi
    kill "$mock_pid" 2>/dev/null
  else
    ok "live LM Studio in use — mock-specific check skipped"
  fi
  rm -rf "$dir"
}

verify_report() {
  section "egress report: an accurate record of where the session went"
  local out reached refused
  out=$(summary claude anthropic '
      curl -s -o /dev/null --max-time 20 https://api.anthropic.com/v1/models
      curl -s -o /dev/null --max-time 20 https://example.com')
  reached=$(sed -n '/^reached:/,/^refused/p' <<<"$out")
  refused=$(sed -n '/^refused/,$p' <<<"$out")

  if [[ -n "$out" ]]; then ok "summary is produced and readable by the agent"
  else bad "summary is produced and readable by the agent"; fi

  if [[ "$reached" == *"api.anthropic.com"* ]]; then ok "allowlisted host listed as reached"
  else bad "allowlisted host listed as reached (reached: ${reached:0:120})"; fi

  if [[ "$refused" == *"example.com"* ]]; then ok "filtered host listed as refused"
  else bad "filtered host listed as refused (refused: ${refused:0:120})"; fi

  # Regression guard: tinyproxy logs the CONNECT request BEFORE filtering it, so
  # a naive parse reports a refused host as one the session reached.
  if [[ "$reached" != *"example.com"* ]]; then ok "filtered host NOT miscounted as reached"
  else bad "filtered host miscounted as reached (reached: ${reached:0:120})"; fi
}

verify_creds() {
  section "credentials: one session, one key; no host config in the guest"
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)

  # Host dotfiles must not be reachable, whatever else is mounted
  check_fails "host ~/.ssh not visible in guest"    ./gopher-hole none "$dir" test -e "${HOME}/.ssh"
  check_fails "host ~/.claude not visible in guest" ./gopher-hole none "$dir" test -e "${HOME}/.claude"
  check_fails "host ~/.aws not visible in guest"    ./gopher-hole none "$dir" test -e "${HOME}/.aws"

  # A keyless posture really is keyless. Sentinel-wrapped so a stray "0"
  # elsewhere in the output cannot pass this.
  check_out "harness 'none' carries no API keys" "KEYCOUNT=0" \
    ./gopher-hole none "$dir" bash -c 'echo "KEYCOUNT=$(env | grep -c _API_KEY= || true)"'

  # Cross-harness key isolation — only runs if both keys exist on the host
  if [[ -n "${ANTHROPIC_API_KEY:-}" && -n "${OPENAI_API_KEY:-}" ]]; then
    check_out "claude session has no OPENAI_API_KEY" "unset" \
      ./gopher-hole claude "$dir" bash -c 'echo "${OPENAI_API_KEY:-unset}"'
    check_out "codex session has no ANTHROPIC_API_KEY" "unset" \
      ./gopher-hole codex "$dir" bash -c 'echo "${ANTHROPIC_API_KEY:-unset}"'
  else
    ok "cross-harness key isolation skipped (both keys not set on host)"
  fi

  # A harness without its key must refuse to start rather than run keyless
  check_fails "claude refuses to launch without ANTHROPIC_API_KEY" \
    env -u ANTHROPIC_API_KEY ./gopher-hole claude "$dir" true
  check_fails "opencode refuses to launch with no key at all" \
    env -u OPENCODE_API_KEY -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
    ./gopher-hole opencode "$dir" true

  # Zen takes precedence, and excludes the provider keys from the session
  if [[ -n "${OPENCODE_API_KEY:-}" ]]; then
    check_out "zen session carries no ANTHROPIC_API_KEY" "unset" \
      env ANTHROPIC_API_KEY=decoy ./gopher-hole opencode "$dir" \
      bash -c 'echo "${ANTHROPIC_API_KEY:-unset}"'
  else
    ok "zen key precedence skipped (OPENCODE_API_KEY not set on host)"
  fi

  rm -rf "$dir"
}

verify_wizard() {
  section "wizard: bare invocation walks agent + inference choices"
  local dir root out_wiz out_exp
  dir=$(cd "$(mktemp -d)" && pwd -P)
  root=$(pwd -P)

  # Menu numbers produce the same invocation as the explicit pair. The
  # explicit calls take </dev/null so both sides are non-TTY: the launcher
  # adds -it only on a TTY, and the wizard side is always piped.
  out_wiz=$(cd "$dir" && printf '4\n4\n\n' | "$root/gopher-hole" --dry-run 2>/dev/null)
  out_exp=$("$root/gopher-hole" --dry-run pi:lmstudio "$dir" </dev/null 2>/dev/null)
  if [[ -n "$out_wiz" && "$out_wiz" == "$out_exp" ]]; then
    ok "menu choices match the explicit pair (pi:lmstudio)"
  else bad "menu choices match the explicit pair (wiz: ${out_wiz:0:80} / exp: ${out_exp:0:80})"; fi

  # Names are accepted as well as numbers
  out_wiz=$(cd "$dir" && printf 'pi\nlmstudio\n\n' | "$root/gopher-hole" --dry-run 2>/dev/null)
  if [[ -n "$out_wiz" && "$out_wiz" == "$out_exp" ]]; then ok "names accepted as choices"
  else bad "names accepted as choices"; fi

  # Enter everywhere lands on the built-in defaults (first harness, its first provider)
  out_wiz=$(cd "$dir" && printf '\n\n\n' | env ANTHROPIC_API_KEY=decoy "$root/gopher-hole" --dry-run 2>/dev/null)
  out_exp=$(env ANTHROPIC_API_KEY=decoy "$root/gopher-hole" --dry-run claude:anthropic "$dir" </dev/null 2>/dev/null)
  if [[ -n "$out_wiz" && "$out_wiz" == "$out_exp" ]]; then
    ok "empty input accepts the defaults (claude:anthropic)"
  else bad "empty input accepts the defaults"; fi

  # Declining the confirmation launches nothing
  out_wiz=$(cd "$dir" && printf '4\n4\nn\n' | "$root/gopher-hole" --dry-run 2>/dev/null)
  if [[ "$out_wiz" != *"container run"* ]]; then ok "answering 'n' aborts the launch"
  else bad "answering 'n' aborts the launch"; fi

  # No harness argument and no input to read: fail with usage, never hang
  check_fails "bare invocation with no input fails with usage" \
    bash -c "cd '$dir' && '$root/gopher-hole' --dry-run </dev/null"

  rm -rf "$dir"
}

verify_run() {
  section "gopher-hole: session launcher"
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  check_out "workdir mirrors the host path" "$dir" ./gopher-hole none "$dir" pwd
  ./gopher-hole none "$dir" touch created-by-agent >/dev/null 2>&1
  check "guest-created file lands on host" test -f "${dir}/created-by-agent"
  local host_email
  host_email=$(git config --global user.email 2>/dev/null || echo "no-host-email")
  check_out "git identity forwarded (env)" "$host_email" ./gopher-hole none "$dir" git var GIT_AUTHOR_IDENT
  check_fails "unknown harness rejected" ./gopher-hole bogus "$dir" true
  rm -rf "$dir"
}

verify_gitro() {
  section "read-only .git: agent edits tree but cannot write git metadata"
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  ( cd "$dir" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'orig\n' > f.txt && git add . && git commit -qm init ) >/dev/null 2>&1
  ./gopher-hole none "$dir" bash -c 'echo agent-edit >> f.txt' >/dev/null 2>&1
  check_out "host sees working-tree edit" "f.txt" bash -c "git -C '$dir' status --short"
  check_fails "agent cannot write .git metadata" \
    ./gopher-hole none "$dir" bash -c 'echo evil > .git/hooks/pre-commit'
  check_fails "agent cannot commit" \
    ./gopher-hole none "$dir" bash -c 'git add -A && git commit -m nope'
  check_out "in-guest git diff still works" "f.txt" ./gopher-hole none "$dir" git diff --stat
  rm -rf "$dir"
}

verify_migration() {
  section "migration: ~/.pi-gopher-hole moves to state/pi-lmstudio exactly once"
  local fake dir
  fake=$(cd "$(mktemp -d)" && pwd -P)
  dir=$(cd "$(mktemp -d)" && pwd -P)
  mkdir -p "${fake}/.pi-gopher-hole/agent"
  echo '{"marker":true}' > "${fake}/.pi-gopher-hole/agent/settings.json"

  env HOME="$fake" GOPHER_STATE_DIR= ./gopher-hole --dry-run pi:lmstudio "$dir" >/dev/null 2>&1
  check "old pi state moved into state/pi-lmstudio" \
    test -f "${fake}/.gopher-hole/state/pi-lmstudio/agent/settings.json"
  check_fails "old ~/.pi-gopher-hole is gone" test -e "${fake}/.pi-gopher-hole"

  # Exactly once: a reappearing old dir must never clobber migrated state
  mkdir -p "${fake}/.pi-gopher-hole"
  echo intruder > "${fake}/.pi-gopher-hole/intruder"
  env HOME="$fake" GOPHER_STATE_DIR= ./gopher-hole --dry-run pi:lmstudio "$dir" >/dev/null 2>&1
  check_fails "second run does not overwrite migrated state" \
    test -e "${fake}/.gopher-hole/state/pi-lmstudio/intruder"

  rm -rf "$fake" "$dir"
}

verify_state() {
  section "state: guest-owned caches persist, host caches untouched"
  local dir marker
  dir=$(cd "$(mktemp -d)" && pwd -P)
  marker="${STATE_ROOT}/cache/npm/verify-marker"
  rm -f "$marker"
  ./gopher-hole none "$dir" bash -c 'echo persisted > /home/agent/.npm/verify-marker' >/dev/null 2>&1
  check "cache write reaches the host state dir" test -f "$marker"
  check_out "cache survives into the next session" "persisted" \
    ./gopher-hole none "$dir" cat /home/agent/.npm/verify-marker
  if command -v go >/dev/null 2>&1; then
    local host_modcache
    host_modcache=$(go env GOMODCACHE)
    check_fails "host Go module cache not mounted" \
      ./gopher-hole none "$dir" test -e "$host_modcache"
  else
    ok "host Go absent — host-cache isolation check skipped"
  fi
  rm -f "$marker"
  rm -rf "$dir"
}

main() {
  local sections=("$@")
  if [[ ${#sections[@]} -eq 0 ]]; then
    sections=(image cli wizard matrix pairs wiring creds_matrix egress firewall_local pi_lmstudio report creds run gitro migration state)
  fi
  for s in "${sections[@]}"; do
    "verify_${s}"
  done
  echo
  echo -e "passed: ${GREEN}${PASS}${NC}  failed: ${RED}${FAIL}${NC}"
  [[ $FAIL -eq 0 ]]
}

main "$@"
