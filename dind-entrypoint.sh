#!/usr/bin/env bash
set -euo pipefail

# Start Docker daemon, then hand off to the base image entrypoint (ironclaw).

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
