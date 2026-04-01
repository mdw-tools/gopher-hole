#!/bin/bash
set -euo pipefail

# Initialize firewall before anything else
/usr/local/bin/init-firewall.sh

# Protect git hooks from modification so they can't be used to
# execute arbitrary code on the host when you run git commands there
if [[ -d /workspace/.git/hooks ]]; then
  echo "[entrypoint] Locking .git/hooks against writes..."
  chmod -R a-w /workspace/.git/hooks
fi

exec "$@"
