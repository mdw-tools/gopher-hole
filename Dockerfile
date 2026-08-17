FROM ubuntu:24.04

# tinyproxy is the guest's only egress path (see init-firewall.sh). The rest is
# the ordinary toolbox: build-essential supplies make plus gcc/g++ for cgo.
# ripgrep and fd-find are baked in because pi wants rg/fd and would otherwise
# try to download them at startup — blocked in the local posture. Debian ships
# fd as 'fdfind'; pi looks for 'fd', hence the symlink.
RUN apt-get update && apt-get install -y \
      curl ca-certificates git build-essential jq ripgrep fd-find python3 perl \
      iproute2 nftables tinyproxy \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd

# Go from the official tarball (apt's golang is stale); arm64 because
# containers on Apple Silicon run linux/arm64
ARG GO_VERSION=1.26.5
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# Node 22 — required by every harness below, and by hunk
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# hunk (diff review TUI) and pi ship plain JS with no postinstall step, so these
# two keep --ignore-scripts. pi is the most provider-agnostic harness here: its
# models.json takes an arbitrary baseUrl, which is how attempt-004 pointed it at
# LM Studio.
ARG PI_VERSION=0.82.1
ARG HUNK_VERSION=0.19.0
# --ignore-scripts also skips the step that marks hunk's platform binary
# executable, so restore the bit by hand.
RUN npm install -g --ignore-scripts \
      "hunkdiff@${HUNK_VERSION}" \
      "@earendil-works/pi-coding-agent@${PI_VERSION}" \
    && chmod +x /usr/lib/node_modules/hunkdiff/node_modules/hunkdiff-linux-*/bin/hunk

# The four harnesses, version-pinned. Unlike hunk, three of these four resolve
# their platform binary in a postinstall script (@anthropic-ai/claude-code,
# opencode-ai, and amp via @ampcode/cli — checked with `npm view <pkg> scripts`),
# so --ignore-scripts installs a CLI that cannot start. Install scripts
# therefore run here: at build time, on pinned versions, in a throwaway image,
# never during a session. See README "Supply chain".
ARG CLAUDE_VERSION=2.1.220
ARG CODEX_VERSION=0.145.0
ARG OPENCODE_VERSION=1.18.5
ARG AMP_VERSION=0.0.1784996198-gd115de
RUN npm install -g \
      "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
      "@openai/codex@${CODEX_VERSION}" \
      "opencode-ai@${OPENCODE_VERSION}" \
      "@sourcegraph/amp@${AMP_VERSION}" \
    && npm cache clean --force

# Every harness reaches the network through the in-guest proxy; a direct
# connection is dropped by nftables, so these must be set for anything to work.
ENV HTTP_PROXY=http://127.0.0.1:8888 \
    HTTPS_PROXY=http://127.0.0.1:8888 \
    http_proxy=http://127.0.0.1:8888 \
    https_proxy=http://127.0.0.1:8888 \
    NO_PROXY=localhost,127.0.0.1 \
    no_proxy=localhost,127.0.0.1

# Pinned versions are only reproducible if nothing updates itself mid-session,
# and telemetry to unallowlisted hosts would just be dropped noise.
#
# OPENCODE_DISABLE_SHARE additionally turns off opencode's conversation sharing,
# which would post session content to opencode's servers — squarely against the
# point of this attempt. (Both OPENCODE_* names were read out of the pinned
# binary rather than guessed at.)
ENV DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    DISABLE_ERROR_REPORTING=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_SHARE=1

# Pre-create the XDG dirs as agent-owned: run.sh mounts volumes beneath them
# (e.g. ~/.cache/go-build), and a mountpoint parent the runtime has to invent
# is created root-owned — leaving the agent unable to mkdir siblings like
# ~/.cache/opencode (EACCES at harness startup).
RUN useradd --create-home --shell /bin/bash agent \
    && mkdir -p /home/agent/.cache /home/agent/.config /home/agent/.local/share \
    && chown -R agent:agent /home/agent

# The mounted repo is host-owned (and .git rides in as a separate read-only
# mount), so git's ownership guard would refuse to operate. Trust any dir —
# safe in this throwaway single-purpose guest.
RUN git config --system --add safe.directory '*'

COPY entrypoint.sh init-firewall.sh setup-harness.sh egress-report.sh \
     providers.sh /usr/local/bin/

# Entry starts as root to install nftables rules and start the proxy, then
# setpriv-drops to 'agent' (see entrypoint.sh) — the agent never has root.
WORKDIR /home/agent
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
