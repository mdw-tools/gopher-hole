#!/bin/bash
# Allowlist-based outbound firewall.
# Permits only the domains Claude Code and Go development require.
set -euo pipefail

ALLOWED_DOMAINS=(
  # Claude API
  "api.anthropic.com"
  "statsig.anthropic.com"

  # Go modules
  "proxy.golang.org"
  "sum.golang.org"
  "golang.org"
  "gopkg.in"
  "storage.googleapis.com"

  # Source / VCS
  "github.com"
  "api.github.com"
  "raw.githubusercontent.com"
  "objects.githubusercontent.com"
  "codeload.github.com"

  # npm (for any Node tooling)
  "registry.npmjs.org"
)

resolve_ips() {
  local domain="$1"
  dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
}

echo "[firewall] Flushing existing rules..."
iptables -F OUTPUT
iptables -F INPUT

# Always allow loopback
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT

# Allow already-established connections
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow DNS so resolution below works (and Go tooling works at runtime)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Resolve and allow each domain
for domain in "${ALLOWED_DOMAINS[@]}"; do
  ips=$(resolve_ips "$domain")
  if [[ -z "$ips" ]]; then
    echo "[firewall] WARNING: could not resolve $domain — skipping"
    continue
  fi
  for ip in $ips; do
    echo "[firewall] ALLOW $domain -> $ip"
    iptables -A OUTPUT -d "$ip" -p tcp --dport 443 -j ACCEPT
    iptables -A OUTPUT -d "$ip" -p tcp --dport 80  -j ACCEPT
  done
done

# Drop everything else outbound
iptables -A OUTPUT -j DROP

echo "[firewall] Done."
