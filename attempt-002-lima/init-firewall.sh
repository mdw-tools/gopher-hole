#!/bin/bash
# Allowlist-based outbound firewall using nftables.
# Permits only the domains Claude Code and Go development require.
# Runs as root during provisioning; non-root user cannot modify rules.
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

  # npm
  "registry.npmjs.org"
)

# Lima's host-agent resolver address, passed via environment or detected.
LIMA_DNS="${LIMA_DNS:-192.168.5.2}"

resolve_ips() {
  local domain="$1"
  dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
}

echo "[firewall] Resolving allowed domains..."
ALLOWED_IPS=()
for domain in "${ALLOWED_DOMAINS[@]}"; do
  ips=$(resolve_ips "$domain")
  if [[ -z "$ips" ]]; then
    echo "[firewall] WARNING: could not resolve $domain — skipping"
    continue
  fi
  for ip in $ips; do
    echo "[firewall] ALLOW $domain -> $ip"
    ALLOWED_IPS+=("$ip")
  done
done

echo "[firewall] Building nftables ruleset..."
cat > /etc/nftables.conf <<'NFTHEAD'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  set allowed_ips {
    type ipv4_addr
    flags interval
NFTHEAD

# Add resolved IPs to the set
{
  echo "    elements = {"
  printf '      %s,\n' "${ALLOWED_IPS[@]}"
  echo "    }"
} >> /etc/nftables.conf

cat >> /etc/nftables.conf <<NFTBODY
  }

  chain output {
    type filter hook output priority 0; policy drop;

    # Always allow loopback
    oifname "lo" accept

    # Allow established/related connections
    ct state established,related accept

    # Allow DNS only to Lima host-agent resolver
    ip daddr ${LIMA_DNS} udp dport 53 accept
    ip daddr ${LIMA_DNS} tcp dport 53 accept

    # Allow HTTPS to allowlisted IPs only
    ip daddr @allowed_ips tcp dport 443 accept

    # Log and drop everything else
    log prefix "[nftables-drop] " drop
  }

  chain input {
    type filter hook input priority 0; policy drop;

    # Allow loopback
    iifname "lo" accept

    # Allow established/related
    ct state established,related accept

    # Drop everything else
    drop
  }
}
NFTBODY

echo "[firewall] Applying nftables ruleset..."
nft -f /etc/nftables.conf

echo "[firewall] Enabling nftables service for persistence across reboots..."
systemctl enable nftables

echo "[firewall] Done. Rules:"
nft list ruleset
