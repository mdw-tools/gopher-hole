FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
      curl ca-certificates git jq ripgrep python3 perl iproute2 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Go from the official tarball (apt's golang is stale); arm64 because
# containers on Apple Silicon run linux/arm64
ARG GO_VERSION=1.26.5
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# Node 22 (required by pi and hunk), then the agent harness and review tool
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && npm install -g --ignore-scripts @earendil-works/pi-coding-agent hunkdiff

RUN useradd --create-home --shell /bin/bash agent

COPY entrypoint.sh setup-pi.sh /usr/local/bin/

USER agent
WORKDIR /home/agent
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["pi"]
