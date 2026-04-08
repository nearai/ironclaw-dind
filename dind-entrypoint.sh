#!/usr/bin/env bash
set -euo pipefail

# Start Docker daemon and SSH server, then hand off to ironclaw as non-root.
# Mirrors the old openclaw-nearai-worker entrypoint behavior: SSH as a
# non-root user, ironclaw runs under that same user via runuser.

IRONCLAW_USER="${IRONCLAW_USER:-ironclaw}"

# Ensure a same-named group exists even on systems where useradd doesn't create user-private groups.
if ! getent group "${IRONCLAW_USER}" >/dev/null 2>&1; then
    echo "Group '${IRONCLAW_USER}' not in group database — creating with groupadd"
    if ! groupadd "${IRONCLAW_USER}"; then
        echo "ERROR: groupadd failed for '${IRONCLAW_USER}'" >&2
        exit 1
    fi
fi

if ! getent passwd "${IRONCLAW_USER}" >/dev/null 2>&1; then
    echo "User '${IRONCLAW_USER}' not in passwd — creating with useradd (home /home/${IRONCLAW_USER})"
    if ! useradd -g "${IRONCLAW_USER}" -m -s /bin/bash -d "/home/${IRONCLAW_USER}" "${IRONCLAW_USER}"; then
        echo "ERROR: useradd failed for '${IRONCLAW_USER}'" >&2
        exit 1
    fi
fi

IRONCLAW_HOME="$(getent passwd "${IRONCLAW_USER}" | cut -d: -f6)"
if [ -z "${IRONCLAW_HOME}" ]; then
    echo "ERROR: Unable to resolve home directory for user '${IRONCLAW_USER}'" >&2
    exit 1
fi
IRONCLAW_GROUP="$(id -gn "${IRONCLAW_USER}" 2>/dev/null || true)"
if [ -z "${IRONCLAW_GROUP}" ]; then
    echo "ERROR: Unable to resolve primary group for user '${IRONCLAW_USER}'" >&2
    exit 1
fi
if [ "${IRONCLAW_HOME#/}" = "${IRONCLAW_HOME}" ]; then
    echo "ERROR: Refusing non-absolute IRONCLAW_HOME '${IRONCLAW_HOME}' for user '${IRONCLAW_USER}'" >&2
    exit 1
fi
if [ "${IRONCLAW_HOME}" = "/" ]; then
    echo "ERROR: Refusing unsafe IRONCLAW_HOME '/' for user '${IRONCLAW_USER}'" >&2
    exit 1
fi

mkdir -p "${IRONCLAW_HOME}"
# Volume mounts often land as root:root; fix the home directory inode only (not a recursive chown).
# Use the explicit primary group for deterministic ownership semantics.
chown "${IRONCLAW_USER}:${IRONCLAW_GROUP}" "${IRONCLAW_HOME}"

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
    chown -R "${IRONCLAW_USER}:${IRONCLAW_GROUP}" "${IRONCLAW_HOME}/.ssh"

    # Generate any missing host keys
    mkdir -p /etc/ssh
    ssh-keygen -A

    # Unlock the user for SSH key-based login (without deleting password)
    usermod -U "${IRONCLAW_USER}" 2>/dev/null || passwd -u "${IRONCLAW_USER}" 2>/dev/null || true

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

# Let non-root user access the Docker daemon.
# usermod -aG docker doesn't take effect under runuser -p (no new login session),
# so we also open the socket directly.
usermod -aG docker "${IRONCLAW_USER}" 2>/dev/null || true
chmod 666 /var/run/docker.sock 2>/dev/null || true

# Pre-pull the sandbox worker image in the background so ironclaw starts immediately.
# Also tag as short name — ironclaw internally references "ironclaw-worker:latest".
SANDBOX_IMAGE="${SANDBOX_IMAGE:-nearaidev/ironclaw-worker:latest}"
(
    if ! docker image inspect "$SANDBOX_IMAGE" > /dev/null 2>&1; then
        echo "Pulling sandbox image ${SANDBOX_IMAGE} in background..."
        docker pull "$SANDBOX_IMAGE" && echo "Sandbox image ready" || echo "WARNING: Failed to pull ${SANDBOX_IMAGE}" >&2
    fi
    docker tag "$SANDBOX_IMAGE" ironclaw-worker:latest 2>/dev/null || true
) &

# ============================================
# OAuth callback (if domain and instance name are available)
# ============================================
if [ -n "${IRONCLAW_DOMAIN:-}" ] && [ -n "${IRONCLAW_INSTANCE_NAME:-}" ]; then
    export IRONCLAW_OAUTH_CALLBACK_URL="https://auth.${IRONCLAW_DOMAIN}"
fi

# ============================================
# Ensure writable dirs
# ============================================
mkdir -p "${IRONCLAW_HOME}/.ironclaw/channels" "${IRONCLAW_HOME}/workspace"
chown -R "${IRONCLAW_USER}:${IRONCLAW_GROUP}" "${IRONCLAW_HOME}/.ironclaw" "${IRONCLAW_HOME}/workspace"

# ============================================
# Start IronClaw with auto-restart
# ============================================
RESTART_DELAY="${IRONCLAW_RESTART_DELAY:-5}"
MAX_FAILURES="${IRONCLAW_MAX_FAILURES:-10}"
FAILURE_COUNT=0

export HOME="${IRONCLAW_HOME}"

while true; do
    echo "Starting IronClaw..."
    chown -R "${IRONCLAW_USER}:${IRONCLAW_GROUP}" "${IRONCLAW_HOME}/.ironclaw" "${IRONCLAW_HOME}/workspace" 2>/dev/null || true
    if [ "$#" -eq 0 ]; then
        runuser -p -u "${IRONCLAW_USER}" -- ironclaw run --no-onboard && EXIT_CODE=0 || EXIT_CODE=$?
    else
        runuser -p -u "${IRONCLAW_USER}" -- ironclaw "$@" && EXIT_CODE=0 || EXIT_CODE=$?
    fi
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
