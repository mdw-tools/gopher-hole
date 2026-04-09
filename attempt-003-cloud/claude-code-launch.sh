#!/usr/bin/env bash
# ==============================================================================
# claude-code-launch.sh
#
# Boots a cloud VM (AWS EC2 or DigitalOcean Droplet) with Claude Code installed,
# rsyncs your current directory to it, and drops you into an SSH session.
#
# Usage:
#   ./claude-code-launch.sh [OPTIONS]
#
# Options:
#   --provider    aws | do                  (default: aws)
#   --size        Instance/droplet size     (default: see DEFAULTS below)
#   --region      Cloud region              (default: us-west-1 / nyc3)
#   --key         SSH key name (cloud-side) (default: claude-cloud)
#   --key-file    Local private key path    (default: ~/.ssh/claude-cloud.pem)
#   --name        Instance name/tag         (default: claude-code-TIMESTAMP)
#   --sync-dir    Directory to rsync        (default: current directory)
#   --help        Show this message
#
# Security:
#   SSH ingress is locked to your current public IP only.
#   The instance is always terminated on exit to avoid lingering credentials.
#   A temporary keypair is generated for syncback; its authorized_keys entry
#   is restricted with command= so it can only run rsync, not a shell.
#
# Prerequisites:
#   AWS:           aws CLI configured (aws configure)
#   DigitalOcean:  doctl CLI configured (doctl auth init) + DIGITALOCEAN_TOKEN set
#   Both:          rsync, ssh
# ==============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PROVIDER="aws"
AWS_SIZE="t3.medium"
DO_SIZE="s-2vcpu-4gb"
AWS_REGION="us-west-1"
DO_REGION="nyc3"
SSH_KEY_NAME="claude-cloud"
SSH_KEY_FILE="${HOME}/.ssh/claude-cloud.pem"
INSTANCE_NAME="claude-code-$(date +%s)"
SYNC_DIR="$(pwd)"
LOCAL_SSH_PORT=2222   # Reverse tunnel port: VM → localhost:22
SYNCBACK_KEY_FILE=""  # Set at runtime after keygen
REMOTE_USER="ubuntu"
REMOTE_DIR="/home/ubuntu/workspace"

# ── Detect local public IP (used to lock down SSH ingress) ──────────────────
detect_my_ip() {
  local ip
  ip=$(curl -sf --max-time 5 https://checkip.amazonaws.com \
    || curl -sf --max-time 5 https://ifconfig.me \
    || curl -sf --max-time 5 https://api.ipify.org) \
    || error "Could not detect your public IP. Check your internet connection."
  # Basic sanity check — must look like an IPv4 address
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || error "Public IP detection returned an unexpected value: ${ip}"
  echo "$ip"
}

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}▶ $*${NC}"; }
success() { echo -e "${GREEN}✓ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠ $*${NC}"; }
error()   { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --size)     AWS_SIZE="$2"; DO_SIZE="$2"; shift 2 ;;
    --region)   AWS_REGION="$2"; DO_REGION="$2"; shift 2 ;;
    --key)      SSH_KEY_NAME="$2"; shift 2 ;;
    --key-file) SSH_KEY_FILE="$2"; shift 2 ;;
    --name)     INSTANCE_NAME="$2"; shift 2 ;;
    --sync-dir) SYNC_DIR="$2"; shift 2 ;;
    --help)
      sed -n '/^# Usage/,/^# =\+$/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0
      ;;
    *) error "Unknown option: $1. Use --help for usage." ;;
  esac
done

# ── Cloud-init / startup script installed on the VM ──────────────────────────
# This runs as root on first boot and installs Claude Code + tools.
read -r -d '' CLOUD_INIT_SCRIPT << 'ENDINIT' || true
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# System packages
apt-get update -qq
apt-get install -y -qq git curl rsync build-essential ripgrep

# Install latest Go directly from go.dev (apt ships a stale version)
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz
echo 'export PATH="/usr/local/go/bin:$PATH"' > /etc/profile.d/go.sh
export PATH="/usr/local/go/bin:$PATH"

# Install Claude Code (native binary — no Node.js required)
curl -fsSL https://claude.ai/install.sh | sudo -u ubuntu bash

# Make claude available system-wide via symlink
CLAUDE_BIN=$(sudo -u ubuntu bash -c 'echo ${HOME}/.claude/bin/claude 2>/dev/null || echo ${HOME}/.local/bin/claude')
if [ -f "$CLAUDE_BIN" ]; then
  ln -sf "$CLAUDE_BIN" /usr/local/bin/claude
fi

# Add to ubuntu's PATH in .bashrc and .profile
for f in /home/ubuntu/.bashrc /home/ubuntu/.profile; do
  grep -q '\.claude/bin\|\.local/bin' "$f" 2>/dev/null || \
    echo 'export PATH="$HOME/.claude/bin:$HOME/.local/bin:$PATH"' >> "$f"
done

# Install plugins from the agentics marketplace
# Use || true on each install so a missing plugin doesn't abort the whole setup
sudo -u ubuntu bash -c '
  export PATH="$HOME/.claude/bin:$HOME/.local/bin:$PATH"
  claude plugin marketplace add mdw-tools/agentics || true
  claude plugin install picard@agentics || true
  claude plugin install data@agentics || true
'

# Create workspace directory
mkdir -p /home/ubuntu/workspace
chown -R ubuntu:ubuntu /home/ubuntu/workspace

# Install syncback function into ubuntu's .bashrc
# The tunnel forwards VM:2222 → host:22, so rsync goes via localhost:2222.
# SYNCBACK_USER, SYNCBACK_DIR, and SYNCBACK_PORT are injected by open_ssh()
# as environment variables over the SSH session.
cat >> /home/ubuntu/.bashrc << 'SYNCEOF'

# ── syncback: push workspace changes to the host machine ──────────────────────
syncback() {
  if [[ -z "${SYNCBACK_USER:-}" || -z "${SYNCBACK_DIR:-}" || -z "${SYNCBACK_PORT:-}" || -z "${SYNCBACK_KEY:-}" ]]; then
    echo "syncback: missing environment variables." >&2
    echo "Was this session started by claude-code-launch.sh?" >&2
    return 1
  fi
  echo "Syncing workspace → ${SYNCBACK_USER}@localhost:${SYNCBACK_DIR} (via tunnel port ${SYNCBACK_PORT})..."
  rsync -avz --progress \
    -e "ssh -p ${SYNCBACK_PORT} -i ${SYNCBACK_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
    --exclude 'node_modules' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    ~/workspace/ \
    "${SYNCBACK_USER}@localhost:${SYNCBACK_DIR}/"
  echo "Done."
}
SYNCEOF

# Leave a README
cat > /home/ubuntu/CLAUDE_READY.md << 'EOF'
# Claude Code Remote Session

Your code has been synced here from your local machine.

## Quick start
```bash
claude
```

## Recommended review workflow
1. Let Claude make changes here (leave them uncommitted)
2. Run `syncback` to pull the working tree to your host
3. Review on your host: `git diff`, IDE diff tools, etc.
4. Commit and push on your host: `git commit && git push`
5. Back here on the VM: `git pull` — git state is back in sync

SSH agent forwarding is active, so `git pull`/`git push` on the VM
authenticate using your local SSH identity automatically.

## Sync uncommitted files (mid-session checkpoint or non-git use)
```bash
syncback
```
This pushes the entire workspace to the host and runs automatically on exit.
EOF

# Signal that setup is complete
touch /tmp/claude-code-ready
ENDINIT

# ── Helper: temporary restricted keypair for syncback ────────────────────────
# Generates a short-lived ed25519 keypair. Installs the public key into
# ~/.ssh/authorized_keys with a command= restriction that permits ONLY rsync
# server invocations — no shell, no port forwarding, no other commands.
# The private key is copied to the VM and used exclusively by syncback().
# Both the key files and the authorized_keys entry are removed on exit.
setup_syncback_key() {
  local tmpdir
  tmpdir=$(mktemp -d)
  SYNCBACK_KEY_FILE="${tmpdir}/syncback_ed25519"

  info "Generating temporary syncback keypair..."
  ssh-keygen -t ed25519 -N "" -C "claude-code-syncback-$$"     -f "$SYNCBACK_KEY_FILE" &>/dev/null
  success "Syncback keypair generated."

  # The command= value: only allow rsync --server invocations.
  # no-port-forwarding etc. are belt-and-suspenders restrictions on top.
  local pubkey
  pubkey=$(cat "${SYNCBACK_KEY_FILE}.pub")
  local restriction
  restriction='command="if [[ "$SSH_ORIGINAL_COMMAND" == rsync\ --server* ]]; then eval "$SSH_ORIGINAL_COMMAND"; else echo Forbidden >&2; exit 1; fi",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty'

  # Ensure ~/.ssh/authorized_keys exists with correct perms
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  touch "${HOME}/.ssh/authorized_keys"
  chmod 600 "${HOME}/.ssh/authorized_keys"

  # Append the restricted entry, tagged so we can remove it precisely later
  local tag="claude-code-syncback-$$"
  echo "${restriction} ${pubkey} ${tag}" >> "${HOME}/.ssh/authorized_keys"
  success "Restricted syncback key installed in ~/.ssh/authorized_keys."
}

teardown_syncback_key() {
  if [[ -z "$SYNCBACK_KEY_FILE" ]]; then return; fi
  local tag="claude-code-syncback-$$"
  info "Removing temporary syncback key from authorized_keys..."
  # Remove the tagged line — use a temp file to avoid in-place sed portability issues
  local tmpfile
  tmpfile=$(mktemp)
  grep -v "$tag" "${HOME}/.ssh/authorized_keys" > "$tmpfile" || true
  mv "$tmpfile" "${HOME}/.ssh/authorized_keys"
  chmod 600 "${HOME}/.ssh/authorized_keys"
  rm -f "$SYNCBACK_KEY_FILE" "${SYNCBACK_KEY_FILE}.pub"
  rmdir "$(dirname "$SYNCBACK_KEY_FILE")" 2>/dev/null || true
  success "Syncback key removed."
}

# ── Helper: wait for SSH ──────────────────────────────────────────────────────
wait_for_ssh() {
  local ip="$1"
  info "Waiting for SSH on ${ip}..."
  local attempts=0
  until ssh -i "$SSH_KEY_FILE" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 \
            -o BatchMode=yes \
            "${REMOTE_USER}@${ip}" true 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 40 ]]; then
      error "Timed out waiting for SSH after $((attempts * 5)) seconds."
    fi
    printf '.'
    sleep 5
  done
  echo
  success "SSH is ready."
}

# ── Helper: wait for cloud-init ───────────────────────────────────────────────
wait_for_setup() {
  local ip="$1"
  info "Waiting for Claude Code installation to complete (may take 2–3 min)..."
  local attempts=0
  until ssh -i "$SSH_KEY_FILE" \
            -o StrictHostKeyChecking=no \
            -o BatchMode=yes \
            "${REMOTE_USER}@${ip}" \
            "test -f /tmp/claude-code-ready" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 60 ]]; then
      warn "Setup is taking longer than expected. Proceeding anyway..."
      break
    fi
    printf '.'
    sleep 5
  done
  echo
  success "Instance setup complete."
}

# ── Helper: propagate host git identity to remote ────────────────────────────
setup_git_config() {
  local ip="$1"
  local git_name git_email
  git_name=$(git config --global user.name 2>/dev/null || true)
  git_email=$(git config --global user.email 2>/dev/null || true)

  if [[ -z "$git_name" && -z "$git_email" ]]; then
    warn "No git user.name or user.email found locally — skipping git config on VM."
    return
  fi

  info "Propagating git identity to VM..."
  ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "${REMOTE_USER}@${ip}" "
    ${git_name:+git config --global user.name $(printf '%q' "$git_name")}
    ${git_email:+git config --global user.email $(printf '%q' "$git_email")}
  "
  success "Git identity set on VM: ${git_name} <${git_email}>"
}

# ── Helper: copy local Claude config files to remote ─────────────────────────
sync_claude_config() {
  local ip="$1"
  local remote_claude_dir="/home/${REMOTE_USER}/.claude"
  local copied=0

  ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "${REMOTE_USER}@${ip}" \
    "mkdir -p ${remote_claude_dir}"

  for f in settings.json CLAUDE.md; do
    local src="${HOME}/.claude/${f}"
    if [[ -f "$src" ]]; then
      info "Copying ~/.claude/${f} to VM..."
      scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -q \
        "$src" "${REMOTE_USER}@${ip}:${remote_claude_dir}/${f}"
      copied=$((copied + 1))
    else
      warn "~/.claude/${f} not found locally — skipping."
    fi
  done

  [[ $copied -gt 0 ]] && success "Claude config copied to VM (${copied} file(s))."
}

# ── Helper: rsync local → remote ──────────────────────────────────────────────
do_rsync() {
  local ip="$1"
  info "Rsyncing ${SYNC_DIR} → ${REMOTE_USER}@${ip}:${REMOTE_DIR}/"
  rsync -avz --progress \
    -e "ssh -i ${SSH_KEY_FILE} -o StrictHostKeyChecking=no" \
    --exclude 'node_modules' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    --exclude '.env' \
    --filter=':- .gitignore' \
    "${SYNC_DIR}/" \
    "${REMOTE_USER}@${ip}:${REMOTE_DIR}/"
  success "Sync complete."
}

# ── Helper: rsync remote → local (sync back Claude's changes) ─────────────────
sync_back() {
  local ip="$1"
  info "Syncing changes back from remote → ${SYNC_DIR}/"
  rsync -avz --progress \
    -e "ssh -i ${SSH_KEY_FILE} -o StrictHostKeyChecking=no" \
    --exclude 'node_modules' \
    --exclude '__pycache__' \
    --exclude '*.pyc' \
    "${REMOTE_USER}@${ip}:${REMOTE_DIR}/" \
    "${SYNC_DIR}/"
  success "Sync back complete. Changes (including any git commits) are now local."
}

# ── Helper: SSH session with reverse tunnel ───────────────────────────────────
# Opens a reverse tunnel: VM:LOCAL_SSH_PORT → host:22
# Copies the restricted private key to the VM so syncback() uses it.
# SYNCBACK_* env vars tell syncback() where and how to connect.
open_ssh() {
  local ip="$1"

  # Warn if no SSH identities are loaded — agent forwarding won't help without them
  if ! ssh-add -l &>/dev/null; then
    warn "No SSH identities in ssh-agent — git push/pull on the VM may fail."
    warn "Run: ssh-add ~/.ssh/your_key  (then re-run this script)"
  fi

  # Copy the restricted private key to the VM
  local remote_key_path="/tmp/syncback_key_$$"
  info "Installing restricted syncback key on VM..."
  scp -i "$SSH_KEY_FILE"       -o StrictHostKeyChecking=no       -q       "$SYNCBACK_KEY_FILE"       "${REMOTE_USER}@${ip}:${remote_key_path}"
  ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no       "${REMOTE_USER}@${ip}" "chmod 600 ${remote_key_path}"

  info "Opening SSH session → ${REMOTE_USER}@${ip}:${REMOTE_DIR}"
  info "Reverse tunnel active: VM port ${LOCAL_SSH_PORT} → your local SSH (port 22)"
  echo -e "${YELLOW}Type 'syncback' on the remote at any time to push changes back.${NC}"
  echo -e "${YELLOW}Changes are also synced automatically when you exit.${NC}"
  ssh -i "$SSH_KEY_FILE" \
      -A \
      -o StrictHostKeyChecking=no \
      -o ExitOnForwardFailure=yes \
      -R "${LOCAL_SSH_PORT}:localhost:22" \
      -t \
      "${REMOTE_USER}@${ip}" \
      "export SYNCBACK_USER=${USER} SYNCBACK_DIR=${SYNC_DIR} SYNCBACK_PORT=${LOCAL_SSH_PORT} SYNCBACK_KEY=${remote_key_path}; \
       cd ${REMOTE_DIR} && exec bash -l"
}

# ==============================================================================
# AWS EC2
# ==============================================================================
launch_aws() {
  command -v aws &>/dev/null || error "aws CLI not found. Install it: https://aws.amazon.com/cli/"
  aws sts get-caller-identity &>/dev/null || error "AWS credentials not configured. Run: aws configure"

  info "Finding latest Ubuntu 22.04 LTS AMI in ${AWS_REGION}..."
  AMI_ID=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners 099720109477 \
    --filters \
      "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
      "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)
  [[ -z "$AMI_ID" ]] && error "Could not find Ubuntu AMI."
  info "Using AMI: ${AMI_ID}"

  setup_syncback_key

  info "Detecting your public IP to restrict SSH ingress..."
  MY_IP=$(detect_my_ip)
  success "SSH will be restricted to: ${MY_IP}/32"

  # Create a temporary security group that allows SSH from your IP only
  SG_NAME="claude-code-sg-$(date +%s)"
  info "Creating security group: ${SG_NAME}..."
  SG_ID=$(aws ec2 create-security-group \
    --region "$AWS_REGION" \
    --group-name "$SG_NAME" \
    --description "Temporary SG for Claude Code dev instance" \
    --query 'GroupId' --output text)

  aws ec2 authorize-security-group-ingress \
    --region "$AWS_REGION" \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "${MY_IP}/32" &>/dev/null

  info "Launching EC2 instance (${AWS_SIZE}) in ${AWS_REGION}..."
  INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$AWS_SIZE" \
    --key-name "$SSH_KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --user-data "$CLOUD_INIT_SCRIPT" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

  success "Instance launched: ${INSTANCE_ID}"

  # Sync back then always terminate on exit
  cleanup_aws() {
    echo ""
    teardown_syncback_key
    sync_back "$PUBLIC_IP" || warn "Sync back failed — instance may already be gone."
    warn "Terminating instance ${INSTANCE_ID}..."
    aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" &>/dev/null || true
    warn "Deleting security group ${SG_ID}..."
    sleep 10
    aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$SG_ID" &>/dev/null || true
    success "Resources cleaned up."
  }
  trap cleanup_aws EXIT

  info "Waiting for instance to be running..."
  aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"

  PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
  success "Public IP: ${PUBLIC_IP}"

  wait_for_ssh "$PUBLIC_IP"
  wait_for_setup "$PUBLIC_IP"
  setup_git_config "$PUBLIC_IP"
  sync_claude_config "$PUBLIC_IP"
  do_rsync "$PUBLIC_IP"
  open_ssh "$PUBLIC_IP"
}

# ==============================================================================
# DigitalOcean Droplet
# ==============================================================================
launch_do() {
  command -v doctl &>/dev/null || error "doctl not found. Install: https://docs.digitalocean.com/reference/doctl/how-to/install/"
  doctl account get &>/dev/null || error "doctl not authenticated. Run: doctl auth init"

  # Look up the SSH key fingerprint by name
  info "Looking up SSH key '${SSH_KEY_NAME}' in your DO account..."
  KEY_ID=$(doctl compute ssh-key list --format Name,FingerPrint --no-header \
    | awk -v k="$SSH_KEY_NAME" '$1 == k {print $2}')

  if [[ -z "$KEY_ID" ]]; then
    warn "SSH key '${SSH_KEY_NAME}' not found in DigitalOcean. Attempting to import from ${SSH_KEY_FILE}.pub ..."
    PUB_KEY_FILE="${SSH_KEY_FILE}.pub"
    [[ -f "$PUB_KEY_FILE" ]] || error "Public key not found at ${PUB_KEY_FILE}"
    doctl compute ssh-key import "$SSH_KEY_NAME" --public-key-file "$PUB_KEY_FILE"
    KEY_ID=$(doctl compute ssh-key list --format Name,FingerPrint --no-header \
      | awk -v k="$SSH_KEY_NAME" '$1 == k {print $2}')
  fi
  success "Using SSH key fingerprint: ${KEY_ID}"

  setup_syncback_key

  info "Detecting your public IP to restrict SSH ingress..."
  MY_IP=$(detect_my_ip)
  success "SSH will be restricted to: ${MY_IP}/32"

  info "Creating DigitalOcean Droplet '${INSTANCE_NAME}' (${DO_SIZE}) in ${DO_REGION}..."
  DROPLET_ID=$(doctl compute droplet create "$INSTANCE_NAME" \
    --image ubuntu-22-04-x64 \
    --size "$DO_SIZE" \
    --region "$DO_REGION" \
    --ssh-keys "$KEY_ID" \
    --user-data "$CLOUD_INIT_SCRIPT" \
    --wait \
    --no-header \
    --format ID \
    | tail -1)

  success "Droplet created: ${DROPLET_ID}"

  # Create a firewall that allows SSH from your IP only
  FW_NAME="claude-code-fw-$(date +%s)"
  info "Creating firewall '${FW_NAME}' restricted to ${MY_IP}..."
  FW_ID=$(doctl compute firewall create "$FW_NAME" \
    --inbound-rules "protocol:tcp,ports:22,address:${MY_IP}/32" \
    --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0 protocol:udp,ports:all,address:0.0.0.0/0" \
    --droplet-ids "$DROPLET_ID" \
    --format ID --no-header)
  success "Firewall created: ${FW_ID}"

  cleanup_do() {
    echo ""
    teardown_syncback_key
    sync_back "$PUBLIC_IP" || warn "Sync back failed — droplet may already be gone."
    warn "Deleting firewall ${FW_ID}..."
    doctl compute firewall delete "$FW_ID" --force &>/dev/null || true
    warn "Deleting droplet ${DROPLET_ID}..."
    doctl compute droplet delete "$DROPLET_ID" --force &>/dev/null || true
    success "Droplet and firewall deleted."
  }
  trap cleanup_do EXIT

  PUBLIC_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header | tail -1)
  success "Public IP: ${PUBLIC_IP}"

  REMOTE_USER="root"
  REMOTE_DIR="/root/workspace"

  wait_for_ssh "$PUBLIC_IP"
  wait_for_setup "$PUBLIC_IP"
  setup_git_config "$PUBLIC_IP"
  sync_claude_config "$PUBLIC_IP"
  do_rsync "$PUBLIC_IP"
  open_ssh "$PUBLIC_IP"
}

# ==============================================================================
# Main
# ==============================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Claude Code Cloud Launcher${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo    "  Provider:  ${PROVIDER}"
echo    "  Sync dir:  ${SYNC_DIR}"
echo    "  SSH key:   ${SSH_KEY_FILE}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

case "$PROVIDER" in
  aws) launch_aws ;;
  do)  launch_do  ;;
  *)   error "Unknown provider '${PROVIDER}'. Use 'aws' or 'do'." ;;
esac