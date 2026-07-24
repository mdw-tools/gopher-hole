#!/usr/bin/env bash
# Smoke tests for attempt-004-apple-container.
#
# Each phase of the proposal adds a section here first (red), then the piece
# that makes it pass (green). Sections appear in phase order.
#
# Usage:
#   ./verify.sh                  # run every section
#   ./verify.sh image pi         # run named sections only
set -uo pipefail

IMAGE="gopher-hole"
PI_STATE_DIR="${HOME}/.pi-gopher-hole"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; FAIL=0

section() { echo -e "${CYAN}--- $*${NC}"; }
ok()      { PASS=$((PASS + 1)); echo -e "${GREEN}  ✓ $*${NC}"; }
bad()     { FAIL=$((FAIL + 1)); echo -e "${RED}  ✗ $*${NC}"; }

# check <description> <command...>  — passes if the command exits 0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# check_out <description> <expected-substring> <command...>
check_out() {
  local desc="$1" expected="$2"; shift 2
  local output
  output=$("$@" 2>&1)
  if [[ "$output" == *"$expected"* ]]; then ok "$desc"; else bad "$desc (got: ${output:0:120})"; fi
}

verify_image() {
  section "image: toolchain baked into '${IMAGE}'"
  check "image '${IMAGE}' exists" container image inspect "${IMAGE}"
  check "git available"     container run --rm "${IMAGE}" git --version
  check "node available"    container run --rm "${IMAGE}" node --version
  check "pi available"      container run --rm "${IMAGE}" pi --version
  check "hunk available"    container run --rm "${IMAGE}" hunk --version
  check "jq available"      container run --rm "${IMAGE}" jq --version
  check "python3 available" container run --rm "${IMAGE}" python3 --version
  check "perl available"    container run --rm "${IMAGE}" perl --version
  check "ip available"      container run --rm "${IMAGE}" ip -V
  check_out "go 1.26 on PATH" "go1.26" container run --rm "${IMAGE}" go version
  check_out "runs as non-root 'agent' user" "agent" container run --rm "${IMAGE}" whoami
}

verify_pi() {
  section "pi: reaches LM Studio through the vmnet gateway"
  mkdir -p "${PI_STATE_DIR}"
  check_out "pi one-shot prompt answers PONG" "PONG" \
    container run --rm -v "${PI_STATE_DIR}:/home/agent/.pi" "${IMAGE}" \
    pi -p --no-session "Reply with exactly: PONG"
}

verify_run() {
  section "run.sh: session launcher"
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  check_out "workdir mirrors the host path" "$dir" ./run.sh "$dir" pwd
  ./run.sh "$dir" touch created-by-agent >/dev/null 2>&1
  check "guest-created file lands on host" test -f "${dir}/created-by-agent"
  local host_email
  host_email=$(git config --global user.email 2>/dev/null || echo "no-host-email")
  check_out "git identity forwarded (env)" "$host_email" ./run.sh "$dir" git var GIT_AUTHOR_IDENT
  rm -rf "$dir"
}

main() {
  local sections=("$@")
  if [[ ${#sections[@]} -eq 0 ]]; then
    sections=(image pi run)
  fi
  for s in "${sections[@]}"; do
    "verify_${s}"
  done
  echo
  echo -e "passed: ${GREEN}${PASS}${NC}  failed: ${RED}${FAIL}${NC}"
  [[ $FAIL -eq 0 ]]
}

main "$@"
