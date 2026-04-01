FROM golang:1.26-bookworm

RUN apt-get update && apt-get install -y \
    git curl ca-certificates iptables dnsutils \
    && rm -rf /var/lib/apt/lists/*

# Go dev tools
RUN go install golang.org/x/tools/gopls@latest \
    && go install github.com/go-delve/delve/cmd/dlv@latest \
    && go install golang.org/x/tools/cmd/goimports@latest

# Node.js + Claude Code
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code

COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
