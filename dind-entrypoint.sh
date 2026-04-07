#!/usr/bin/env bash
set -euo pipefail

# Start Docker daemon and SSH server, then hand off to ironclaw.

# ============================================
# SSH Server
# ============================================
if [ -n "${SSH_PUBKEY:-}" ]; then
    echo "Configuring SSH..."
    SSH_USER="${SSH_USER:-root}"
    SSH_HOME="$(getent passwd "${SSH_USER}" | cut -d: -f6)"
    if [ -z "${SSH_HOME}" ]; then
        echo "ERROR: Unable to resolve home directory for SSH user '${SSH_USER}'" >&2
        exit 1
    fi

    mkdir -p "${SSH_HOME}/.ssh"
    echo "${SSH_PUBKEY}" > "${SSH_HOME}/.ssh/authorized_keys"
    if [ -n "${BASTION_SSH_PUBKEY:-}" ]; then
        echo "${BASTION_SSH_PUBKEY}" >> "${SSH_HOME}/.ssh/authorized_keys"
    fi
    chmod 700 "${SSH_HOME}/.ssh"
    chmod 600 "${SSH_HOME}/.ssh/authorized_keys"
    chown -R "${SSH_USER}:${SSH_USER}" "${SSH_HOME}/.ssh"

    # Generate any missing host keys
    mkdir -p /etc/ssh
    ssh-keygen -A

    mkdir -p /run/sshd
    if ! /usr/sbin/sshd -p 2222 -o PasswordAuthentication=no -o PrintMotd=no; then
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

# Pre-pull the sandbox worker image in the background so ironclaw starts immediately.
SANDBOX_IMAGE="${SANDBOX_IMAGE:-nearaidev/ironclaw-worker:latest}"
(
    if ! docker image inspect "$SANDBOX_IMAGE" > /dev/null 2>&1; then
        echo "Pulling sandbox image ${SANDBOX_IMAGE} in background..."
        docker pull "$SANDBOX_IMAGE" && echo "Sandbox image ready" || echo "WARNING: Failed to pull ${SANDBOX_IMAGE}" >&2
    fi
) &

exec ironclaw "$@"
