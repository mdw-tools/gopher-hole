#!/usr/bin/env bash
# Container entrypoint, in two stages:
#   root:  start the egress proxy + firewall, then drop to the 'agent' user
#   agent: write the harness config, run the session, report egress on exit
#
# Unlike attempt-004, egress setup failure is fatal. There the fallback was
# harmless (the guest simply had no network rules and no credentials); here the
# proxy is the only route out and a real API key is present, so a session that
# came up without the ruleset would be an unfiltered agent holding a credential.
# Fail closed, loudly.
set -euo pipefail

if [[ $(id -u) -eq 0 ]]; then
  /usr/local/bin/init-firewall.sh
  # env vars (GOPHER_*, GIT_*, *_API_KEY) are preserved; only identity/HOME change
  exec setpriv --reuid=agent --regid=agent --init-groups \
    env HOME=/home/agent USER=agent LOGNAME=agent \
    "$0" "$@"
fi

# shellcheck source=providers.sh
. /usr/local/bin/providers.sh
if [[ "$(provider_posture "${GOPHER_PROVIDER:-none}")" == "local" ]]; then
  # No proxy exists in the local posture; the image-baked proxy env would send
  # every HTTP client to a closed port.
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
fi

/usr/local/bin/setup-harness.sh

# Provider wiring that must reach the harness process itself (e.g.
# CLAUDE_CODE_USE_BEDROCK, ANTHROPIC_BASE_URL). setup-harness.sh is a child
# process, so it writes these out and we source them here.
if [[ -f /home/agent/.gopher-provider-env ]]; then
  # shellcheck source=/dev/null
  . /home/agent/.gopher-provider-env
fi

# Not exec'd: the egress report runs after the session command exits. The
# session's exit status is preserved.
set +e
"$@"
RC=$?
set -e

/usr/local/bin/egress-report.sh || true

exit "$RC"
