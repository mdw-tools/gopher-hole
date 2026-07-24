#!/usr/bin/env bash
# Default-drop egress allowlist, applied by the entrypoint's root stage before
# privileges drop to the non-root 'agent' user. Because each container is its
# own VM, these rules live in a separate guest kernel the agent cannot reach.
#
# Allowed egress:
#   - loopback, established/related
#   - DNS to the guest's resolver (the vmnet gateway) only
#   - LM Studio on the host gateway (LMSTUDIO_PORT, default 1234)
#   - HTTPS to git hosts and the Go module proxy (resolved at container start)
set -euo pipefail

GW=$(ip route | awk '/default/ {print $3; exit}')
PORT="${LMSTUDIO_PORT:-1234}"

ALLOWED_DOMAINS=(
  github.com
  api.github.com
  codeload.github.com
  objects.githubusercontent.com
  raw.githubusercontent.com
  bitbucket.org
  proxy.golang.org
  sum.golang.org
  storage.googleapis.com
)

nft add table inet gopher
nft add chain inet gopher output '{ type filter hook output priority 0; policy drop; }'
nft add rule inet gopher output oif lo accept
nft add rule inet gopher output ct state established,related accept
# DNS via the gateway resolver only; needed below before any names resolve
nft add rule inet gopher output ip daddr "$GW" udp dport 53 accept
nft add rule inet gopher output ip daddr "$GW" tcp dport 53 accept
nft add rule inet gopher output ip daddr "$GW" tcp dport "$PORT" accept

for domain in "${ALLOWED_DOMAINS[@]}"; do
  for ip in $(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u); do
    nft add rule inet gopher output ip daddr "$ip" tcp dport 443 accept
  done
done
