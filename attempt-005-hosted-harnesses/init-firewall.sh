#!/usr/bin/env bash
# Guest egress control. Runs as root from the entrypoint, before privileges drop.
#
# tinyproxy is the ONLY process permitted to leave the VM, and it forwards
# CONNECTs to allowlisted hostnames only:
#
#   agent (non-root) ──127.0.0.1:8888──> tinyproxy ──:443──> allowlisted host
#                    └── anything else ──> DROP (nftables, guest kernel)
#
# Two properties an IP allowlist cannot give:
#
#   * CDN-fronted hosts work reliably. api.anthropic.com, api.openai.com and
#     ampcode.com sit behind large, short-TTL address pools; resolving them once
#     at startup and pinning the addresses (attempt-004's approach) goes stale
#     mid-session and presents as a flaky harness rather than a firewall error.
#     Filtering on the CONNECT hostname has no such failure mode.
#   * The agent user gets no DNS whatsoever, so DNS-query exfiltration stays
#     closed even though the model API is reachable. Only tinyproxy resolves,
#     and only names that already passed the filter.
#
# The agent cannot subvert any of this: the config and filter file are
# root-owned, the ruleset lives in a kernel it has no access to, and setpriv
# strips CAP_NET_ADMIN before the session command runs.
set -euo pipefail

HARNESS="${GOPHER_HARNESS:-none}"
PROXY_PORT="${GOPHER_PROXY_PORT:-8888}"
CONF=/etc/tinyproxy/gopher.conf
FILTER=/etc/tinyproxy/gopher-allow.txt
LOG_DIR=/var/log/tinyproxy
LOG="${LOG_DIR}/gopher.log"

# --- allowlist -------------------------------------------------------------
# Only the selected harness's endpoints are reachable, so a claude session
# cannot talk to OpenAI and vice versa. Toolchain hosts are shared: in-guest
# `go get` and `npm install` work without sharing any host cache.
DOMAINS=(
  proxy.golang.org
  sum.golang.org
  storage.googleapis.com
  registry.npmjs.org
)
case "$HARNESS" in
  claude)   DOMAINS+=(api.anthropic.com) ;;
  codex)    DOMAINS+=(api.openai.com) ;;
  opencode)
    # Zen (opencode's own pay-per-usage gateway) needs only opencode.ai, so a
    # Zen session cannot reach the provider APIs at all. run.sh picks the mode
    # from which credential is present. models.dev is the model catalog.
    case "${GOPHER_OPENCODE_MODE:-direct}" in
      zen)    DOMAINS+=(opencode.ai models.dev) ;;
      direct) DOMAINS+=(api.anthropic.com api.openai.com models.dev) ;;
      *) echo "init-firewall: unknown opencode mode '${GOPHER_OPENCODE_MODE}'" >&2; exit 1 ;;
    esac
    ;;
  amp)      DOMAINS+=(ampcode.com) ;;
  none)     ;;  # toolchain only — a sandbox shell with no model access
  *) echo "init-firewall: unknown harness '${HARNESS}'" >&2; exit 1 ;;
esac

# Opt-in additions for this session (comma-separated), e.g. a private module host
if [[ -n "${EGRESS_EXTRA_HOSTS:-}" ]]; then
  read -r -a extra <<<"${EGRESS_EXTRA_HOSTS//,/ }"
  DOMAINS+=("${extra[@]}")
fi

# Anchored, dot-escaped exact matches — a bare 'api.openai.com' as an extended
# regex would also match 'api-openai.com.evil.example'.
: > "$FILTER"
for domain in "${DOMAINS[@]}"; do
  printf '^%s$\n' "${domain//./\\.}" >> "$FILTER"
done
chmod 0644 "$FILTER"

# --- proxy -----------------------------------------------------------------
mkdir -p "$LOG_DIR"
chown tinyproxy:tinyproxy "$LOG_DIR"
# The distro package ships this dir 0750, which blocks the agent from even
# traversing it — the end-of-session egress report could not read its own log.
chmod 0755 "$LOG_DIR"

# FilterDefaultDeny turns the filter file into a whitelist: anything not listed
# is refused. ConnectPort 443 keeps CONNECT from becoming a general TCP tunnel.
# LogLevel Connect records every request — the session's egress record.
cat > "$CONF" <<EOF
User tinyproxy
Group tinyproxy
Port ${PROXY_PORT}
Listen 127.0.0.1
Allow 127.0.0.1
Timeout 600
MaxClients 100
LogFile "${LOG}"
LogLevel Connect
Filter "${FILTER}"
FilterType ere
FilterDefaultDeny Yes
FilterCaseSensitive No
ConnectPort 443
EOF
chmod 0644 "$CONF"

tinyproxy -c "$CONF"

# The log must be agent-readable so the end-of-session summary works; it is
# tinyproxy-owned, so the agent can read its own egress record but not forge it.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$LOG" ]] && break
  sleep 0.2
done
[[ -f "$LOG" ]] || { echo "init-firewall: tinyproxy failed to start" >&2; exit 1; }
chmod 0644 "$LOG"

# --- ruleset ---------------------------------------------------------------
TP_UID=$(id -u tinyproxy)

nft add table inet gopher
nft add chain inet gopher output '{ type filter hook output priority 0; policy drop; }'
nft add rule inet gopher output oif lo accept
nft add rule inet gopher output ct state established,related accept
nft add rule inet gopher output meta skuid "$TP_UID" tcp dport 443 accept

# DNS for tinyproxy only, and only to the resolvers the guest was handed.
# IPv4 only; IPv6 falls through to the drop policy.
NAMESERVERS=$(awk '/^nameserver/ && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf)
if [[ -z "$NAMESERVERS" ]]; then
  echo "init-firewall: no IPv4 nameserver in /etc/resolv.conf — proxy cannot resolve" >&2
  exit 1
fi
for ns in $NAMESERVERS; do
  nft add rule inet gopher output meta skuid "$TP_UID" ip daddr "$ns" udp dport 53 accept
  nft add rule inet gopher output meta skuid "$TP_UID" ip daddr "$ns" tcp dport 53 accept
done

# Diagnostic, not session output — keep stdout clean for the session command.
echo "egress: harness=${HARNESS} via 127.0.0.1:${PROXY_PORT} — allowed: ${DOMAINS[*]}" >&2
