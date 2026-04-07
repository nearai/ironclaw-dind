#!/usr/bin/env bash
set -euo pipefail

# Start Docker daemon and SSH server, then hand off to ironclaw as non-root.
# Mirrors the old openclaw-nearai-worker entrypoint behavior: SSH as a
# non-root user, ironclaw runs under that same user via runuser.

IRONCLAW_USER="ironclaw"
IRONCLAW_HOME="$(getent passwd "${IRONCLAW_USER}" | cut -d: -f6)"
if [ -z "${IRONCLAW_HOME}" ]; then
    echo "ERROR: Unable to resolve home directory for user '${IRONCLAW_USER}'" >&2
    exit 1
fi

# ============================================
# SSH Server (non-root, port 2222)
# ============================================
if [ -n "${SSH_PUBKEY:-}" ]; then
    echo "Configuring SSH..."
    mkdir -p "${IRONCLAW_HOME}/.ssh"
    echo "${SSH_PUBKEY}" > "${IRONCLAW_HOME}/.ssh/authorized_keys"
    if [ -n "${BASTION_SSH_PUBKEY:-}" ]; then
        echo "${BASTION_SSH_PUBKEY}" >> "${IRONCLAW_HOME}/.ssh/authorized_keys"
    fi
    chmod 755 "${IRONCLAW_HOME}"
    chmod 700 "${IRONCLAW_HOME}/.ssh"
    chmod 600 "${IRONCLAW_HOME}/.ssh/authorized_keys"
    chown -R "${IRONCLAW_USER}:${IRONCLAW_USER}" "${IRONCLAW_HOME}/.ssh"

    # Generate any missing host keys
    mkdir -p /etc/ssh
    ssh-keygen -A

    # Unlock the user for SSH key-based login
    passwd -d "${IRONCLAW_USER}" 2>/dev/null || usermod -U "${IRONCLAW_USER}" 2>/dev/null || true

    mkdir -p /run/sshd
    if ! /usr/sbin/sshd -p 2222 \
        -o PasswordAuthentication=no \
        -o PermitRootLogin=no \
        -o PrintMotd=no \
        -o PidFile=/run/sshd/sshd.pid; then
        echo "ERROR: Failed to start SSH daemon" >&2
        exit 1
    fi
    echo "SSH daemon started on port 2222"
else
    echo "SSH_PUBKEY not set — SSH access disabled"
fi

# ============================================
# Docker Daemon
# ============================================
dockerd > /var/log/dockerd.log 2>&1 &

elapsed=0
while ! docker info > /dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge 120 ]; then
        echo "ERROR: Docker daemon did not start within 120s" >&2
        cat /var/log/dockerd.log >&2
        exit 1
    fi
done
echo "Docker daemon ready after ${elapsed}s"

# Add ironclaw user to the docker group so it can use the daemon
usermod -aG docker "${IRONCLAW_USER}" 2>/dev/null || true

# Pre-pull the sandbox worker image in the background so ironclaw starts immediately.
SANDBOX_IMAGE="${SANDBOX_IMAGE:-nearaidev/ironclaw-worker:latest}"
(
    if ! docker image inspect "$SANDBOX_IMAGE" > /dev/null 2>&1; then
        echo "Pulling sandbox image ${SANDBOX_IMAGE} in background..."
        docker pull "$SANDBOX_IMAGE" && echo "Sandbox image ready" || echo "WARNING: Failed to pull ${SANDBOX_IMAGE}" >&2
    fi
) &

# ============================================
# Secrets master key (generate-once, root-locked)
# ============================================
MASTER_KEY_FILE="${IRONCLAW_HOME}/.ironclaw/.master_key"
mkdir -p "${IRONCLAW_HOME}/.ironclaw/channels" "${IRONCLAW_HOME}/workspace"
if [ -z "${SECRETS_MASTER_KEY:-}" ]; then
    if [ -f "$MASTER_KEY_FILE" ]; then
        SECRETS_MASTER_KEY=$(cat "$MASTER_KEY_FILE")
    else
        SECRETS_MASTER_KEY=$(openssl rand -hex 32)
        echo "$SECRETS_MASTER_KEY" > "$MASTER_KEY_FILE"
    fi
    export SECRETS_MASTER_KEY
fi

# ============================================
# OAuth callback (if domain and instance name are available)
# ============================================
if [ -n "${OPENCLAW_DOMAIN:-}" ] && [ -n "${OPENCLAW_INSTANCE_NAME:-}" ]; then
    export IRONCLAW_OAUTH_CALLBACK_URL="https://auth.${OPENCLAW_DOMAIN}"
    export IRONCLAW_INSTANCE_NAME="${OPENCLAW_INSTANCE_NAME}"
fi

# ============================================
# Ownership fix and master key lock
# ============================================
chown -R "${IRONCLAW_USER}:${IRONCLAW_USER}" "${IRONCLAW_HOME}/.ironclaw" "${IRONCLAW_HOME}/workspace"
# Lock master key so the ironclaw user (and AI shell tool) cannot read it.
# The process inherits SECRETS_MASTER_KEY via env.
if [ -f "$MASTER_KEY_FILE" ]; then
    chown root:root "$MASTER_KEY_FILE"
    chmod 600 "$MASTER_KEY_FILE"
fi

# ============================================
# Start IronClaw with auto-restart
# ============================================
RESTART_DELAY="${IRONCLAW_RESTART_DELAY:-5}"
MAX_FAILURES="${IRONCLAW_MAX_FAILURES:-10}"
FAILURE_COUNT=0

export HOME="${IRONCLAW_HOME}"

while true; do
    echo "Starting IronClaw..."
    chown -R "${IRONCLAW_USER}:${IRONCLAW_USER}" "${IRONCLAW_HOME}/.ironclaw" "${IRONCLAW_HOME}/workspace" 2>/dev/null || true
    # Re-lock master key after chown -R
    if [ -f "$MASTER_KEY_FILE" ]; then
        chown root:root "$MASTER_KEY_FILE"
        chmod 600 "$MASTER_KEY_FILE"
    fi
    runuser -p -u "${IRONCLAW_USER}" -- ironclaw run --no-onboard "$@"
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ]; then
        FAILURE_COUNT=0
    else
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        echo "IronClaw exited with code $EXIT_CODE (failure $FAILURE_COUNT/$MAX_FAILURES)"
    fi
    if [ $FAILURE_COUNT -ge $MAX_FAILURES ]; then
        echo "IronClaw failed $MAX_FAILURES times consecutively. Exiting." >&2
        exit 1
    fi
    echo "Restarting in ${RESTART_DELAY}s..."
    sleep "$RESTART_DELAY"
done
