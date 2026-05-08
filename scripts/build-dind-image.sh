#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <image-ref> <ironclaw-image> <source-digest>"
  exit 2
fi

IMAGE_REF="$1"
IRONCLAW_IMAGE="$2"
SOURCE_DIGEST="$3"
BUILD_LOG="$(mktemp)"
BASE_IMAGE_REF="${IMAGE_REF}-prebake"
SANDBOX_TAR="$(mktemp -t ironclaw-sandbox-image.XXXXXX.tar)"
trap 'rm -f "$BUILD_LOG" "$SANDBOX_TAR"; docker image rm "$BASE_IMAGE_REF" >/dev/null 2>&1 || true' EXIT

default_sandbox_image() {
  local image_ref="$1"
  local without_digest="${image_ref%%@*}"
  local last_component="${without_digest##*/}"
  local tag="latest"

  if [[ "$last_component" == *:* ]]; then
    tag="${last_component##*:}"
  fi

  echo "nearaidev/ironclaw-worker:${tag}"
}

SANDBOX_IMAGE="${SANDBOX_IMAGE:-$(default_sandbox_image "$IRONCLAW_IMAGE")}"

run_build() {
  local image_ref="$1"
  local extra_flag="${2:-}"
  local args=(
    docker build
    --pull
    --build-arg "IRONCLAW_IMAGE=${IRONCLAW_IMAGE}"
    --build-arg "IRONCLAW_SOURCE_DIGEST=${SOURCE_DIGEST}"
    -t "${image_ref}"
  )

  if [[ -n "$extra_flag" ]]; then
    args+=("$extra_flag")
  fi

  args+=(.)
  "${args[@]}"
}

echo "Preparing sandbox image archive: ${SANDBOX_IMAGE}"
docker pull "${SANDBOX_IMAGE}"
docker save "${SANDBOX_IMAGE}" -o "${SANDBOX_TAR}"

set +e
run_build "$BASE_IMAGE_REF" 2>&1 | tee "$BUILD_LOG"
first_exit="${PIPESTATUS[0]}"
set -e

if [[ "$first_exit" -ne 0 ]]; then
  if grep -Eq "parent snapshot sha256:[a-f0-9]{64} does not exist" "$BUILD_LOG"; then
    echo "Detected orphaned BuildKit snapshot cache entry. Pruning builder cache and retrying once with --no-cache..."
    docker builder prune -af
    run_build "$BASE_IMAGE_REF" --no-cache
  else
    echo "Build failed for a reason other than missing BuildKit parent snapshot cache."
    exit "$first_exit"
  fi
fi

bash ./scripts/bake-inner-image.sh \
  "$BASE_IMAGE_REF" \
  "$SANDBOX_TAR" \
  "$IMAGE_REF" \
  "$SANDBOX_IMAGE" \
  "$SOURCE_DIGEST"
