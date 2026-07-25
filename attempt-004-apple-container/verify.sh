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

# check_fails <description> <command...>  — passes if the command exits non-zero
check_fails() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi
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
  check "make available"    container run --rm "${IMAGE}" make --version
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

verify_firewall() {
  section "firewall: locked-down egress (LM Studio only by default)"
  # Firewalled runs mirror run.sh: CAP_NET_ADMIN for the entrypoint's root stage
  local locked=(container run --rm --cap-add CAP_NET_ADMIN "${IMAGE}")
  local vcs=(container run --rm --cap-add CAP_NET_ADMIN --env EGRESS_ALLOW_VCS=1 "${IMAGE}")

  # Default posture: only LM Studio reachable; git/go get happen on the host
  check "LM Studio via gateway allowed (default)" \
    "${locked[@]}" bash -c \
    'curl -fsS --max-time 10 "http://$(ip route | awk "/default/ {print \$3; exit}"):${LMSTUDIO_PORT:-1234}/v1/models"'
  check_fails "example.com blocked (default)" \
    "${locked[@]}" curl -fsS --max-time 10 https://example.com
  check_fails "github blocked by default" \
    "${locked[@]}" curl -fsS --max-time 10 https://github.com

  # Opt-in posture: VCS + Go proxy re-enabled for in-guest fetches
  check "github allowed with EGRESS_ALLOW_VCS=1" \
    "${vcs[@]}" git ls-remote https://github.com/apple/container.git HEAD
  check "bitbucket allowed with EGRESS_ALLOW_VCS=1" \
    "${vcs[@]}" git ls-remote https://bitbucket.org/atlassian/aui.git HEAD
  check "go module proxy allowed with EGRESS_ALLOW_VCS=1" \
    "${vcs[@]}" bash -c \
    'mkdir -p /tmp/scratch-mod && cd /tmp/scratch-mod && go mod init scratch >/dev/null 2>&1 && go get golang.org/x/text@latest'
}

verify_gitro() {
  section "read-only .git: agent edits tree but cannot write git metadata"
  local dir
  dir=$(cd "$(mktemp -d)" && pwd -P)
  ( cd "$dir" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'orig\n' > f.txt && git add . && git commit -qm init ) >/dev/null 2>&1
  # Agent edits the working tree — succeeds, and the host sees it
  ./run.sh "$dir" bash -c 'echo agent-edit >> f.txt' >/dev/null 2>&1
  check_out "host sees working-tree edit" "f.txt" bash -c "git -C '$dir' status --short"
  # Agent cannot write into .git (commit / hook injection blocked)
  check_fails "agent cannot write .git metadata" \
    ./run.sh "$dir" bash -c 'echo evil > .git/hooks/pre-commit'
  # Read-only git inspection still works in-guest (for hunk, diffs)
  check_out "in-guest git diff still works" "f.txt" ./run.sh "$dir" git diff --stat
  rm -rf "$dir"
}

verify_gocache() {
  section "go module cache: offline build from a shared read-only cache"
  command -v go >/dev/null 2>&1 || { ok "host Go absent — cache-share test skipped"; return; }
  local sb
  sb=$(cd "$(mktemp -d)" && pwd -P)
  mkdir -p "$sb/mod" "$sb/proj"
  cat > "$sb/proj/go.mod" <<'EOF'
module demo
go 1.26
require golang.org/x/text v0.3.8
EOF
  cat > "$sb/proj/main.go" <<'EOF'
package main
import "golang.org/x/text/language"
func main() { println(language.English.String()) }
EOF
  # Pre-fetch into a temp module cache on the host (host has network), leaving a
  # complete go.sum — just like a real checked-in project
  ( cd "$sb/proj" && GOMODCACHE="$sb/mod" go mod tidy ) >/dev/null 2>&1
  # Build in-guest offline (GOPROXY=off), module cache mounted read-only —
  # mirrors run.sh's flags under the locked-egress default
  check "offline go build from read-only shared cache" \
    container run --rm --cap-add CAP_NET_ADMIN \
      -v "$sb/proj:$sb/proj" -v "$sb/mod:$sb/mod:ro" \
      -e "GOMODCACHE=$sb/mod" -e "GOCACHE=/tmp/gobuild" -e "GOPROXY=off" \
      -w "$sb/proj" "${IMAGE}" go build -o /tmp/demo ./...
  # run.sh wires the (real) host cache read-only and GOPROXY=off by default
  check_out "run.sh sets GOPROXY=off under locked egress" "off" \
    ./run.sh "$sb/proj" bash -c 'go env GOPROXY'
  check_out "run.sh keeps GOCACHE guest-local" "/home/agent" \
    ./run.sh "$sb/proj" bash -c 'go env GOCACHE'
  # Module cache files are mode 0444; make writable before removing
  chmod -R +w "$sb" 2>/dev/null || true
  rm -rf "$sb"
}

main() {
  local sections=("$@")
  if [[ ${#sections[@]} -eq 0 ]]; then
    sections=(image pi run firewall gitro gocache)
  fi
  for s in "${sections[@]}"; do
    "verify_${s}"
  done
  echo
  echo -e "passed: ${GREEN}${PASS}${NC}  failed: ${RED}${FAIL}${NC}"
  [[ $FAIL -eq 0 ]]
}

main "$@"
