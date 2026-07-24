#!/usr/bin/env bash
# Container entrypoint, in two stages:
#   root:  apply the egress firewall, then drop to the 'agent' user
#   agent: prepare pi's provider config, then hand off to the session command
set -euo pipefail

if [[ $(id -u) -eq 0 ]]; then
  /usr/local/bin/init-firewall.sh || echo "warning: firewall setup failed — continuing without egress rules" >&2
  # env vars (GIT_*, LMSTUDIO_*) are preserved; only identity/HOME change
  exec setpriv --reuid=agent --regid=agent --init-groups \
    env HOME=/home/agent USER=agent LOGNAME=agent \
    "$0" "$@"
fi

/usr/local/bin/setup-pi.sh || echo "warning: pi provider setup failed — is LM Studio serving on the local network?" >&2

exec "$@"
