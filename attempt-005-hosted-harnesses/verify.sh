#!/usr/bin/env bash
# Smoke tests for attempt-005-hosted-harnesses.
#
# The egress and credential sections are the interesting ones: they assert the
# claims the README makes, including the negative ones (a claude session cannot
# reach OpenAI; the agent user has no DNS at all).
#
# Usage:
#   ./verify.sh                    # run every section
#   ./verify.sh image egress       # run named sections only
set -uo pipefail

IMAGE="gopher-hole-hosted"
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

# guest <harness> <command...> — a session without run.sh, so the egress tests
# don't depend on having API keys set. CAP_NET_ADMIN mirrors run.sh.
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

verify_matrix() {
  section "matrix: every valid pair gets its own provider's host and no other's"
  # Table-driven on purpose. Hand-written per-combo tests would drift from
  # providers.sh, and a stale entry there is the failure mode that matters: a
  # session that carries one provider's key while the firewall opens another's
  # would still WORK, so nothing would draw attention to it.
  local harness provider host others other_host reached refused out ok_all
  for harness in $(all_harnesses); do
    for provider in $(harness_providers "$harness"); do
      [[ "$provider" == "none" || "$provider" == "custom" ]] && continue

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
      case "$provider" in
        bedrock) expect="AWS_BEARER_TOKEN_BEDROCK" ;;
        *)       expect=$(provider_cred_vars "$provider") ;;
      esac

      # Ask the guest for its env var NAMES only and filter here, where the
      # credential list lives — no quoting gymnastics inside bash -c, and no
      # chance of a decoy value landing in the test output.
      out=$(env "${decoys[@]}" AWS_REGION=us-east-1 \
              ./run.sh "${harness}:${provider}" "$dir" \
              bash -c 'env | cut -d= -f1' 2>/dev/null | sort -u)

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
  check_fails "amp:bedrock rejected"       ./run.sh amp:bedrock "$dir" true
  check_fails "codex:anthropic rejected"   ./run.sh codex:anthropic "$dir" true
  check_fails "claude:openai rejected"     ./run.sh claude:openai "$dir" true
  check_fails "codex:bedrock rejected (no verified config path)" \
    ./run.sh codex:bedrock "$dir" true
  check_fails "unknown provider rejected"  ./run.sh claude:bogus "$dir" true
  check_fails "unknown harness rejected"   ./run.sh bogus:anthropic "$dir" true
  check_out "claude defaults to anthropic" "GOPHER_PROVIDER=anthropic" \
    env ANTHROPIC_API_KEY=decoy ./run.sh claude "$dir" \
    bash -c 'echo "GOPHER_PROVIDER=${GOPHER_PROVIDER}"'
  check_out "opencode defaults to zen" "GOPHER_PROVIDER=zen" \
    env OPENCODE_API_KEY=decoy ./run.sh opencode "$dir" \
    bash -c 'echo "GOPHER_PROVIDER=${GOPHER_PROVIDER}"'
  check_fails "bedrock without any AWS credential refused" \
    env -u AWS_BEARER_TOKEN_BEDROCK -u AWS_ACCESS_KEY_ID \
    ./run.sh claude:bedrock "$dir" true
  check_fails "custom without CUSTOM_BASE_URL refused" \
    env -u CUSTOM_BASE_URL ./run.sh claude:custom "$dir" true
  rm -rf "$dir"
}

verify_wiring() {
  section "provider wiring: harness actually pointed at the chosen provider"
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  # claude+bedrock must set claude's own Bedrock switch in the session env
  check_out "claude:bedrock sets CLAUDE_CODE_USE_BEDROCK" "USE_BEDROCK=1" \
    env AWS_BEARER_TOKEN_BEDROCK=decoy AWS_REGION=us-east-1 \
    ./run.sh claude:bedrock "$dir" \
    bash -c 'echo "USE_BEDROCK=${CLAUDE_CODE_USE_BEDROCK:-unset}"'
  check_out "claude:anthropic leaves it unset" "USE_BEDROCK=unset" \
    env ANTHROPIC_API_KEY=decoy ./run.sh claude:anthropic "$dir" \
    bash -c 'echo "USE_BEDROCK=${CLAUDE_CODE_USE_BEDROCK:-unset}"'
  # custom endpoint: base url reaches the harness, and only its host is allowed
  check_out "claude:custom sets ANTHROPIC_BASE_URL" "example.org" \
    env CUSTOM_BASE_URL=https://gw.example.org/v1 CUSTOM_API_KEY=decoy \
    ./run.sh claude:custom "$dir" bash -c 'echo "${ANTHROPIC_BASE_URL:-unset}"'
  check_out "codex:custom writes a model_providers block" "gopher_custom" \
    env CUSTOM_BASE_URL=https://gw.example.org/v1 CUSTOM_API_KEY=decoy \
    ./run.sh codex:custom "$dir" cat /home/agent/.codex/config.toml
  # pi is new here: prove it launched and got its provider config
  check_out "pi:anthropic generates a models.json for a pinned MODEL" "anthropic-messages" \
    env ANTHROPIC_API_KEY=decoy MODEL=claude-sonnet-4-5 \
    ./run.sh pi:anthropic "$dir" cat /home/agent/.pi/agent/models.json
  check_out "pi:bedrock uses bedrock-converse-stream" "bedrock-converse-stream" \
    env AWS_BEARER_TOKEN_BEDROCK=decoy MODEL=anthropic.claude-sonnet-4-v1:0 \
    ./run.sh pi:bedrock "$dir" cat /home/agent/.pi/agent/models.json
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
  check_fails "host ~/.ssh not visible in guest"    ./run.sh none "$dir" test -e "${HOME}/.ssh"
  check_fails "host ~/.claude not visible in guest" ./run.sh none "$dir" test -e "${HOME}/.claude"
  check_fails "host ~/.aws not visible in guest"    ./run.sh none "$dir" test -e "${HOME}/.aws"

  # A keyless posture really is keyless. Sentinel-wrapped so a stray "0"
  # elsewhere in the output cannot pass this.
  check_out "harness 'none' carries no API keys" "KEYCOUNT=0" \
    ./run.sh none "$dir" bash -c 'echo "KEYCOUNT=$(env | grep -c _API_KEY= || true)"'

  # Cross-harness key isolation — only runs if both keys exist on the host
  if [[ -n "${ANTHROPIC_API_KEY:-}" && -n "${OPENAI_API_KEY:-}" ]]; then
    check_out "claude session has no OPENAI_API_KEY" "unset" \
      ./run.sh claude "$dir" bash -c 'echo "${OPENAI_API_KEY:-unset}"'
    check_out "codex session has no ANTHROPIC_API_KEY" "unset" \
      ./run.sh codex "$dir" bash -c 'echo "${ANTHROPIC_API_KEY:-unset}"'
  else
    ok "cross-harness key isolation skipped (both keys not set on host)"
  fi

  # A harness without its key must refuse to start rather than run keyless
  check_fails "claude refuses to launch without ANTHROPIC_API_KEY" \
    env -u ANTHROPIC_API_KEY ./run.sh claude "$dir" true
  check_fails "opencode refuses to launch with no key at all" \
    env -u OPENCODE_API_KEY -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
    ./run.sh opencode "$dir" true

  # Zen takes precedence, and excludes the provider keys from the session
  if [[ -n "${OPENCODE_API_KEY:-}" ]]; then
    check_out "zen session carries no ANTHROPIC_API_KEY" "unset" \
      env ANTHROPIC_API_KEY=decoy ./run.sh opencode "$dir" \
      bash -c 'echo "${ANTHROPIC_API_KEY:-unset}"'
  else
    ok "zen key precedence skipped (OPENCODE_API_KEY not set on host)"
  fi

  rm -rf "$dir"
}

verify_run() {
  section "run.sh: session launcher"
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  check_out "workdir mirrors the host path" "$dir" ./run.sh none "$dir" pwd
  ./run.sh none "$dir" touch created-by-agent >/dev/null 2>&1
  check "guest-created file lands on host" test -f "${dir}/created-by-agent"
  local host_email
  host_email=$(git config --global user.email 2>/dev/null || echo "no-host-email")
  check_out "git identity forwarded (env)" "$host_email" ./run.sh none "$dir" git var GIT_AUTHOR_IDENT
  check_fails "unknown harness rejected" ./run.sh bogus "$dir" true
  rm -rf "$dir"
}

verify_gitro() {
  section "read-only .git: agent edits tree but cannot write git metadata"
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  ( cd "$dir" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'orig\n' > f.txt && git add . && git commit -qm init ) >/dev/null 2>&1
  ./run.sh none "$dir" bash -c 'echo agent-edit >> f.txt' >/dev/null 2>&1
  check_out "host sees working-tree edit" "f.txt" bash -c "git -C '$dir' status --short"
  check_fails "agent cannot write .git metadata" \
    ./run.sh none "$dir" bash -c 'echo evil > .git/hooks/pre-commit'
  check_fails "agent cannot commit" \
    ./run.sh none "$dir" bash -c 'git add -A && git commit -m nope'
  check_out "in-guest git diff still works" "f.txt" ./run.sh none "$dir" git diff --stat
  rm -rf "$dir"
}

verify_state() {
  section "state: guest-owned caches persist, host caches untouched"
  local dir marker
  dir=$(cd "$(mktemp -d)" && pwd -P)
  marker="${STATE_ROOT}/cache/npm/verify-marker"
  rm -f "$marker"
  ./run.sh none "$dir" bash -c 'echo persisted > /home/agent/.npm/verify-marker' >/dev/null 2>&1
  check "cache write reaches the host state dir" test -f "$marker"
  check_out "cache survives into the next session" "persisted" \
    ./run.sh none "$dir" cat /home/agent/.npm/verify-marker
  if command -v go >/dev/null 2>&1; then
    local host_modcache
    host_modcache=$(go env GOMODCACHE)
    check_fails "host Go module cache not mounted" \
      ./run.sh none "$dir" test -e "$host_modcache"
  else
    ok "host Go absent — host-cache isolation check skipped"
  fi
  rm -f "$marker"
  rm -rf "$dir"
}

main() {
  local sections=("$@")
  if [[ ${#sections[@]} -eq 0 ]]; then
    sections=(image matrix pairs wiring creds_matrix egress report creds run gitro state)
  fi
  for s in "${sections[@]}"; do
    "verify_${s}"
  done
  echo
  echo -e "passed: ${GREEN}${PASS}${NC}  failed: ${RED}${FAIL}${NC}"
  [[ $FAIL -eq 0 ]]
}

main "$@"
