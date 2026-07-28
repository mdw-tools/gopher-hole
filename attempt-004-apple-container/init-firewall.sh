#!/usr/bin/env bash
# Default-drop egress allowlist, applied by the entrypoint's root stage before
# privileges drop to the non-root 'agent' user. Because each container is its
# own VM, these rules live in a separate guest kernel the agent cannot reach.
#
# Default posture (locked down): the only reachable destination is LM Studio —
# on the host gateway, or on a remote machine when LMSTUDIO_HOST (an IPv4
# literal) is set. Git and `go get` are expected to happen on the host, so no
# VCS or DNS egress is allowed — this also closes the DNS-query exfil channel.
#
# Opt-in posture (EGRESS_ALLOW_VCS=1): additionally allow DNS via the gateway
# resolver and HTTPS to git hosts and the Go module proxy, for workflows that
# need in-guest `git`/`go get`.
set -euo pipefail

GW=$(ip route | awk '/default/ {print $3; exit}')
PORT="${LMSTUDIO_PORT:-1234}"
LM_HOST="${LMSTUDIO_HOST:-$GW}"

nft add table inet gopher
nft add chain inet gopher output '{ type filter hook output priority 0; policy drop; }'
nft add rule inet gopher output oif lo accept
nft add rule inet gopher output ct state established,related accept
nft add rule inet gopher output ip daddr "$LM_HOST" tcp dport "$PORT" accept

if [[ "${EGRESS_ALLOW_VCS:-0}" == "1" ]]; then
  # DNS via the gateway resolver only — needed to resolve the hosts below
  nft add rule inet gopher output ip daddr "$GW" udp dport 53 accept
  nft add rule inet gopher output ip daddr "$GW" tcp dport 53 accept

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
  for domain in "${ALLOWED_DOMAINS[@]}"; do
    for ip in $(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u); do
      nft add rule inet gopher output ip daddr "$ip" tcp dport 443 accept
    done
  done
fi
