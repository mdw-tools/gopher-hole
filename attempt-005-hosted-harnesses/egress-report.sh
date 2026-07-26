#!/usr/bin/env bash
# Print where the session actually went, from tinyproxy's log.
#
# With a hosted model the allowlist is not a confidentiality boundary — anything
# the agent can read can be encoded into a model request. Visibility is the
# compensating control: an unexpected host here, or a refusal you did not
# expect, is worth investigating.
set -uo pipefail

LOG=/var/log/tinyproxy/gopher.log
[[ -r "$LOG" ]] || exit 0

# "Established connection to host" is logged only after the filter passes and
# the TCP connection succeeds. The earlier "Request ... CONNECT host:443" line
# is logged BEFORE filtering, so counting those would list a refused host as
# reached — exactly backwards for the one thing this report exists to tell you.
ALLOWED=$(grep -oE 'Established connection to host "[^"]+"' "$LOG" 2>/dev/null \
  | sed 's/.*"\(.*\)"/\1/' | sort | uniq -c | sort -rn)
REFUSED=$(grep -oE 'filtered domain "[^"]+"' "$LOG" 2>/dev/null | sed 's/.*"\(.*\)"/\1/' | sort | uniq -c | sort -rn)

[[ -z "$ALLOWED" && -z "$REFUSED" ]] && exit 0

echo
echo "--- egress summary (this session) ---"
if [[ -n "$ALLOWED" ]]; then
  echo "reached:"
  echo "$ALLOWED" | sed 's/^/  /'
fi
if [[ -n "$REFUSED" ]]; then
  echo "refused (not on the allowlist):"
  echo "$REFUSED" | sed 's/^/  /'
fi
