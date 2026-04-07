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
# Ensure writable dirs and drop to non-root
# ============================================
mkdir -p "${IRONCLAW_HOME}/.ironclaw" "${IRONCLAW_HOME}/workspace"
chown -R "${IRONCLAW_USER}:${IRONCLAW_USER}" "${IRONCLAW_HOME}/.ironclaw" "${IRONCLAW_HOME}/workspace"

exec runuser -p -u "${IRONCLAW_USER}" -- ironclaw "$@"
