#!/usr/bin/env bash
set -euo pipefail

# Start Docker daemon in the background.
# The worker entrypoint (/app/entrypoint.sh) handles everything else:
# SSH setup, IronClaw configuration, user switching, and the main process loop.

echo "Starting Docker daemon..."
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

exec /app/entrypoint.sh "$@"
