#!/usr/bin/env bash
# ==============================================================================
# setup_ssh_users.sh - Generic SSH Tunnel Hardening Script
# Target OS: Ubuntu 24.04 LTS / Debian 12
# Must be executed as ROOT (sudo)
# ==============================================================================
# Usage:
#   sudo ./scripts/setup_ssh_users.sh <user1> [user2 user3 ...]
# Example:
#   sudo ./scripts/setup_ssh_users.sh alice bob analyst_prod
# ==============================================================================

set -euo pipefail

# Visual log helpers
log_info() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
log_err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }

# 1. Root privileges verification
if [[ $EUID -ne 0 ]]; then
    log_err "This script must be executed with root privileges. Usage: sudo $0 <user1> [user2 ...]"
    exit 1
fi

# 2. Argument validation
if [[ $# -eq 0 ]]; then
    echo "========================================================================"
    echo "  SSH Bastion User Setup for Database Tunneling"
    echo "========================================================================"
    echo "Usage:   sudo $0 <username_1> [username_2 ... username_N]"
    echo "Example: sudo $0 alice bob data_scientist_1"
    echo "========================================================================"
    exit 1
fi

# 3. Environment & Configuration Loading
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

# Load POSTGRES_HOST_PORT from .env if available, fallback to 5433
POSTGRES_HOST_PORT="${POSTGRES_HOST_PORT:-}"
if [[ -z "$POSTGRES_HOST_PORT" ]] && [[ -f "$ENV_FILE" ]]; then
    POSTGRES_HOST_PORT=$(grep -E '^POSTGRES_HOST_PORT=' "$ENV_FILE" | cut -d '=' -f2 | tr -d ' "\r\n' || true)
fi
POSTGRES_HOST_PORT="${POSTGRES_HOST_PORT:-5433}"

TUNNEL_GROUP="db_tunnelers"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
BACKUP_CONFIG="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

log_info "Target PostgreSQL Loopback Port: 127.0.0.1:${POSTGRES_HOST_PORT}"

# 4. Ensure /bin/false is declared in /etc/shells (required by PAM authentication)
if ! grep -qxF "/bin/false" /etc/shells; then
    log_info "Declaring /bin/false in /etc/shells for PAM compliance..."
    echo "/bin/false" >> /etc/shells
fi

# 5. Ensure the restricted tunnel group exists
if getent group "$TUNNEL_GROUP" >/dev/null 2>&1; then
    log_info "Group '$TUNNEL_GROUP' already exists."
else
    log_info "Creating group '$TUNNEL_GROUP'..."
    groupadd "$TUNNEL_GROUP"
fi

# 6. Apply hardened Match Group configuration to SSH Daemon
log_info "Backing up SSH config to $BACKUP_CONFIG..."
cp "$SSHD_CONFIG" "$BACKUP_CONFIG"

TUNNEL_RULES=$(cat <<EOF
# ==============================================================================
# RESTRICTED TUNNEL GROUP: ${TUNNEL_GROUP}
# Enforces strictly port forwarding to PostgreSQL and forbids shell access.
# ==============================================================================
Match Group ${TUNNEL_GROUP}
    AllowTcpForwarding yes
    PermitOpen 127.0.0.1:${POSTGRES_HOST_PORT}
    X11Forwarding no
    AllowAgentForwarding no
    PermitTTY no
    ForceCommand /bin/false
EOF
)

# Use modular sshd_config.d if present and included in sshd_config
if [[ -d "$SSHD_CONFIG_D" ]] && grep -qE "^\s*Include\s+/etc/ssh/sshd_config.d/\*\.conf" "$SSHD_CONFIG"; then
    CONF_FILE="${SSHD_CONFIG_D}/99-db-tunnelers.conf"
    log_info "Writing restricted tunnel configuration to $CONF_FILE..."
    echo "$TUNNEL_RULES" > "$CONF_FILE"
    chmod 644 "$CONF_FILE"
else
    log_info "Injecting restricted tunnel configuration into $SSHD_CONFIG..."
    # Clean previous block if re-run
    sed -i "/# === RESTRICTED TUNNEL GROUP: ${TUNNEL_GROUP} ===/,/ForceCommand \/bin\/false/d" "$SSHD_CONFIG"
    echo "" >> "$SSHD_CONFIG"
    echo "$TUNNEL_RULES" >> "$SSHD_CONFIG"
fi

# 7. Validate SSH Daemon configuration before creating users or reloading
log_info "Validating SSH daemon syntax (sshd -t)..."
if ! sshd -t; then
    log_err "CRITICAL: SSH configuration validation failed! Reverting to $BACKUP_CONFIG..."
    cp "$BACKUP_CONFIG" "$SSHD_CONFIG"
    exit 1
fi

# 8. Loop through all provided usernames
log_info "Provisioning non-shell tunnel users..."
for USERNAME in "$@"; do
    # Sanitize username format
    if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_warn "Skipping invalid username '$USERNAME'. Must match ^[a-z_][a-z0-9_-]*$"
        continue
    fi

    if id "$USERNAME" >/dev/null 2>&1; then
        log_warn "User '$USERNAME' already exists. Synchronizing group '$TUNNEL_GROUP' and shell /bin/false..."
        usermod -g "$TUNNEL_GROUP" -s /bin/false "$USERNAME"
    else
        log_info "Creating user '$USERNAME' with restricted shell /bin/false..."
        useradd -m -g "$TUNNEL_GROUP" -s /bin/false "$USERNAME"
    fi

    USER_HOME=$(eval echo "~$USERNAME")
    SSH_DIR="${USER_HOME}/.ssh"
    AUTH_KEYS="${SSH_DIR}/authorized_keys"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    chown -R "${USERNAME}:${TUNNEL_GROUP}" "$SSH_DIR"

    log_info "  -> User '$USERNAME' prepared. Keys path: $AUTH_KEYS"
done

# 9. Reload SSH Daemon service
log_info "Reloading SSH service..."
if systemctl is-active --quiet ssh; then
    systemctl reload ssh
elif systemctl is-active --quiet sshd; then
    systemctl reload sshd
else
    log_warn "Could not reload ssh/sshd service automatically. Please run: systemctl reload ssh"
fi

log_info "========================================================================"
log_info "SSH Tunnel Hardening successfully completed!"
log_info "Next Step: Add public keys into each user's authorized_keys:"
for USERNAME in "$@"; do
    echo "  echo \"ssh-ed25519 AAAAC3NzaC...\" | sudo tee -a /home/$USERNAME/.ssh/authorized_keys"
done
log_info "========================================================================"
