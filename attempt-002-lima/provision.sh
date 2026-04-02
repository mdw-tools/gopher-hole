#!/bin/bash
# Provision the Lima VM with dev tools: Go, Node.js, Claude Code.
# Called during VM creation via gopher-hole.yaml provisioning.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[provision] Installing base packages..."
apt-get update
apt-get install -y \
  git make curl ca-certificates build-essential \
  nftables dnsutils jq

echo "[provision] Installing Go (latest stable ARM64)..."
GO_VERSION=$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '.[0].version')
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-arm64.tar.gz" | tar -C /usr/local -xz
echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh

echo "[provision] Installing Node.js 22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
rm -rf /var/lib/apt/lists/*

echo "[provision] Installing Claude Code..."
npm install -g @anthropic-ai/claude-code

echo "[provision] Installing Go dev tools as Lima user..."
sudo -u "${LIMA_CIDATA_USER}" bash -c '
  export PATH=$PATH:/usr/local/go/bin
  export GOPATH=$HOME/go
  go install golang.org/x/tools/gopls@latest
  go install github.com/go-delve/delve/cmd/dlv@latest
  go install golang.org/x/tools/cmd/goimports@latest
'

echo "[provision] Setting up firewall..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Detect Lima's DNS resolver address from the default route gateway.
LIMA_DNS=$(ip route show default | awk '{print $3}' | head -1)
export LIMA_DNS
bash "${SCRIPT_DIR}/init-firewall.sh"

echo "[provision] Done."
