#!/usr/bin/env bash
# The harness × provider matrix — the single source of truth.
#
# Sourced by BOTH run.sh (host, decides credentials) and init-firewall.sh
# (guest, decides the egress allowlist), so a session's key set and its
# reachable hosts are always derived from the same table. That coupling is the
# point: the old hardcoded 1:1 case statement could not express "claude against
# bedrock" without risking a session that carried one provider's key while the
# firewall opened another provider's host.
#
# Kept bash-3.2 compatible: macOS /bin/bash is 3.2, so no associative arrays.
#
# Every claim encoded below was read out of the pinned harness binaries rather
# than from documentation. See README "Provider matrix".

# harness_providers <harness> — valid providers; the FIRST is that harness's default
harness_providers() {
  case "$1" in
    claude)   echo "anthropic bedrock custom" ;;
    codex)    echo "openai custom" ;;
    opencode) echo "zen anthropic openai bedrock" ;;
    pi)       echo "anthropic openai bedrock custom" ;;
    amp)      echo "amp" ;;
    none)     echo "none" ;;
    *) return 1 ;;
  esac
}

harness_default_provider() {
  set -- $(harness_providers "$1") || return 1
  echo "$1"
}

harness_supports() {
  local p
  for p in $(harness_providers "$1" 2>/dev/null); do
    [ "$p" = "$2" ] && return 0
  done
  return 1
}

# url_host <url> — hostname only, no scheme, path or port
url_host() {
  local h="${1#*://}"
  h="${h%%/*}"
  echo "${h%%:*}"
}

# provider_model_hosts <provider> — hostnames this provider needs reachable.
# Bedrock is region-scoped; cross-region inference profiles fan out across
# several regional endpoints, so BEDROCK_REGIONS accepts a comma-separated list.
provider_model_hosts() {
  case "$1" in
    anthropic) echo "api.anthropic.com" ;;
    openai)    echo "api.openai.com" ;;
    zen)       echo "opencode.ai" ;;
    amp)       echo "ampcode.com" ;;
    bedrock)
      local regions r out=""
      regions="${BEDROCK_REGIONS:-${AWS_REGION:-us-east-1}}"
      for r in $(echo "$regions" | tr ',' ' '); do
        out="${out} bedrock-runtime.${r}.amazonaws.com"
      done
      echo "$out"
      ;;
    custom)
      [ -n "${CUSTOM_BASE_URL:-}" ] || return 1
      url_host "$CUSTOM_BASE_URL"
      ;;
    none) echo "" ;;
    *) return 1 ;;
  esac
}

# harness_extra_hosts <harness> — needed regardless of provider
harness_extra_hosts() {
  case "$1" in
    opencode) echo "models.dev" ;;   # model catalog
    *) echo "" ;;
  esac
}

# provider_cred_vars <provider> — env var names to forward from host to guest.
# Bedrock lists the bearer token FIRST deliberately: AWS_BEARER_TOKEN_BEDROCK is
# scoped to Bedrock, whereas AWS_ACCESS_KEY_ID is a general AWS credential whose
# blast radius is whatever IAM allows. run.sh prefers the bearer token and warns
# on the fallback. See README "Bedrock without widening the blast radius".
provider_cred_vars() {
  case "$1" in
    anthropic) echo "ANTHROPIC_API_KEY" ;;
    openai)    echo "OPENAI_API_KEY" ;;
    zen)       echo "OPENCODE_API_KEY" ;;
    amp)       echo "AMP_API_KEY" ;;
    bedrock)   echo "AWS_BEARER_TOKEN_BEDROCK AWS_ACCESS_KEY_ID" ;;
    custom)    echo "CUSTOM_API_KEY" ;;
    none)      echo "" ;;
    *) return 1 ;;
  esac
}

# all_provider_cred_vars — every credential name the matrix knows about, used to
# assert that a session carries ONLY its own provider's key
all_provider_cred_vars() {
  echo "ANTHROPIC_API_KEY OPENAI_API_KEY OPENCODE_API_KEY AMP_API_KEY" \
       "AWS_BEARER_TOKEN_BEDROCK AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY" \
       "AWS_SESSION_TOKEN CUSTOM_API_KEY"
}

all_harnesses() { echo "claude codex opencode pi amp none"; }
