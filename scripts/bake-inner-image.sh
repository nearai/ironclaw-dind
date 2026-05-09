#!/usr/bin/env bash
# Pre-loads the sandbox image into a DinD image's inner Docker storage via
# docker commit, so nested containers start with the image already cached.
# Usage: ./bake-inner-image.sh <dind-image> <sandbox-tar> <output-tag> [sandbox-image] [ironclaw-source-digest]
set -euo pipefail

USAGE="Usage: $0 <dind-image> <sandbox-tar> <output-tag> [sandbox-image] [ironclaw-source-digest]"
DIND_IMAGE="${1:?$USAGE}"
SANDBOX_TAR="${2:?$USAGE}"
OUTPUT_TAG="${3:?$USAGE}"
SANDBOX_IMAGE="${4:-}"
IRONCLAW_SOURCE_DIGEST="${5:-}"
DIND_BAKE_RUN_ARGS="${DIND_BAKE_RUN_ARGS:---runtime=sysbox-runc}"
read -r -a DIND_BAKE_RUN_ARGS_ARRAY <<< "$DIND_BAKE_RUN_ARGS"

CONTAINER_NAME="dind-bake-$$"

echo "==> Starting temporary DinD container from $DIND_IMAGE..."
docker run "${DIND_BAKE_RUN_ARGS_ARRAY[@]}" -d --name "$CONTAINER_NAME" \
    --entrypoint /bin/sh \
    "$DIND_IMAGE" -c "dockerd > /var/log/dockerd.log 2>&1 & sleep infinity"

trap 'docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true' EXIT

echo "==> Copying sandbox archive..."
docker cp "$(realpath "$SANDBOX_TAR")" "$CONTAINER_NAME":/tmp/sandbox.tar

echo "==> Waiting for inner dockerd..."
elapsed=0
while ! docker exec "$CONTAINER_NAME" docker info > /dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge 60 ]; then
        echo "ERROR: inner dockerd did not start within 60s" >&2
        docker exec "$CONTAINER_NAME" cat /var/log/dockerd.log 2>/dev/null >&2 || true
        exit 1
    fi
done
echo "    Inner dockerd ready after ${elapsed}s"

echo "==> Loading sandbox image..."
LOAD_OUTPUT=$(docker exec "$CONTAINER_NAME" docker load -i /tmp/sandbox.tar)
docker exec "$CONTAINER_NAME" rm -f /tmp/sandbox.tar
LOADED_IMAGE=$(echo "$LOAD_OUTPUT" | sed -n 's/^Loaded image: //p' | tail -1)
if [ -z "$LOADED_IMAGE" ]; then
    # Image had no tag — fall back to the image ID
    LOADED_IMAGE=$(echo "$LOAD_OUTPUT" | sed -n 's/^Loaded image ID: //p' | tail -1)
fi
if [ -z "$LOADED_IMAGE" ]; then
    echo "ERROR: could not determine loaded image name from: $LOAD_OUTPUT" >&2
    exit 1
fi
SANDBOX_IMAGE="${SANDBOX_IMAGE:-$LOADED_IMAGE}"
if [ "$LOADED_IMAGE" != "$SANDBOX_IMAGE" ]; then
    echo "==> Tagging $LOADED_IMAGE as $SANDBOX_IMAGE..."
    docker exec "$CONTAINER_NAME" docker tag "$LOADED_IMAGE" "$SANDBOX_IMAGE"
fi
echo "==> Stopping inner dockerd..."
docker exec "$CONTAINER_NAME" sh -c '
    [ -f /var/run/docker.pid ] && kill "$(cat /var/run/docker.pid)" 2>/dev/null
    [ -f /run/docker/containerd/containerd.pid ] && kill "$(cat /run/docker/containerd/containerd.pid)" 2>/dev/null
    sleep 3
'

COMMIT_ARGS=(
    -c 'ENTRYPOINT ["/usr/local/bin/dind-entrypoint.sh"]'
    -c "ENV SANDBOX_IMAGE=$SANDBOX_IMAGE"
    -c "ENV SANDBOX_AUTO_PULL=false"
    -c "LABEL sandbox.image=$SANDBOX_IMAGE"
)
if [ -n "$IRONCLAW_SOURCE_DIGEST" ]; then
    COMMIT_ARGS+=(-c "LABEL ironclaw.source.digest=$IRONCLAW_SOURCE_DIGEST")
fi

echo "==> Committing container as $OUTPUT_TAG..."
docker commit "${COMMIT_ARGS[@]}" "$CONTAINER_NAME" "$OUTPUT_TAG"
