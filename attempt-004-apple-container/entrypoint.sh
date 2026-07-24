#!/usr/bin/env bash
# Container entrypoint: prepare pi's provider config, then hand off to the
# session command (default: pi).
set -euo pipefail

/usr/local/bin/setup-pi.sh || echo "warning: pi provider setup failed — is LM Studio serving on the local network?" >&2

exec "$@"
