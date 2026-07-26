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
  container run --rm --cap-add CAP_NET_ADMIN --env "GOPHER_HARNESS=${harness}" "${IMAGE}" "$@"
}

# summary <harness> <opencode-mode> <shell-script> — run a session and echo only
# its end-of-session egress summary. Asserting against the summary alone matters:
# the firewall's startup line names the same hostnames, so matching the whole
# output would let a test pass on the wrong evidence.
summary() {
  local harness="$1" mode="$2" script="$3"
  container run --rm --cap-add CAP_NET_ADMIN \
    --env "GOPHER_HARNESS=${harness}" --env "GOPHER_OPENCODE_MODE=${mode}" \
    "${IMAGE}" bash -c "$script" 2>&1 | sed -n '/--- egress summary/,$p'
}

verify_image() {
  section "image: toolchain and all four harnesses baked into '${IMAGE}'"
  check "image '${IMAGE}' exists" container image inspect "${IMAGE}"
  check "claude available"   guest none claude --version
  check "codex available"    guest none codex --version
  check "opencode available" guest none opencode --version
  check "amp available"      guest none amp --version
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
  # from the real host rather than a proxy refusal.
  check_out "claude session reaches api.anthropic.com" "401" \
    guest claude curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    https://api.anthropic.com/v1/models
  check_out "codex session reaches api.openai.com" "401" \
    guest codex curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    https://api.openai.com/v1/models

  # Cross-harness isolation: one session, one provider
  check_fails "claude session cannot reach api.openai.com" \
    guest claude curl -fsS --max-time 20 https://api.openai.com/v1/models
  check_fails "codex session cannot reach api.anthropic.com" \
    guest codex curl -fsS --max-time 20 https://api.anthropic.com/v1/models

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

verify_zen() {
  section "opencode Zen: gateway reachable, provider APIs walled off"
  # Zen routes to many models behind one credential, so a Zen session has no
  # business reaching api.anthropic.com or api.openai.com — and cannot.
  local out reached refused
  out=$(summary opencode zen '
      curl -s -o /dev/null --max-time 20 https://opencode.ai/zen/v1/models
      curl -s -o /dev/null --max-time 20 https://api.anthropic.com/v1/models')
  reached=$(sed -n '/^reached:/,/^refused/p' <<<"$out")
  refused=$(sed -n '/^refused/,$p' <<<"$out")

  if [[ "$reached" == *"opencode.ai"* ]]; then ok "zen gateway opencode.ai reached"
  else bad "zen gateway opencode.ai reached (reached: ${reached:0:120})"; fi

  if [[ "$refused" == *"api.anthropic.com"* ]]; then ok "zen session refused api.anthropic.com"
  else bad "zen session refused api.anthropic.com (refused: ${refused:0:120})"; fi

  # Direct mode is the mirror image: provider APIs open, gateway not needed
  out=$(summary opencode direct '
      curl -s -o /dev/null --max-time 20 https://api.anthropic.com/v1/models
      curl -s -o /dev/null --max-time 20 https://opencode.ai/zen/v1/models')
  reached=$(sed -n '/^reached:/,/^refused/p' <<<"$out")
  refused=$(sed -n '/^refused/,$p' <<<"$out")

  if [[ "$reached" == *"api.anthropic.com"* ]]; then ok "direct mode reaches api.anthropic.com"
  else bad "direct mode reaches api.anthropic.com (reached: ${reached:0:120})"; fi

  if [[ "$refused" == *"opencode.ai"* ]]; then ok "direct mode refuses the zen gateway"
  else bad "direct mode refuses the zen gateway (refused: ${refused:0:120})"; fi
}

verify_report() {
  section "egress report: an accurate record of where the session went"
  local out reached refused
  out=$(summary claude direct '
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
    sections=(image egress zen report creds run gitro state)
  fi
  for s in "${sections[@]}"; do
    "verify_${s}"
  done
  echo
  echo -e "passed: ${GREEN}${PASS}${NC}  failed: ${RED}${FAIL}${NC}"
  [[ $FAIL -eq 0 ]]
}

main "$@"
