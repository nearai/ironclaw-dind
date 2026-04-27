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
trap 'rm -f "$BUILD_LOG"' EXIT

run_build() {
  local extra_flag="${1:-}"
  local args=(
    docker build
    --pull
    --build-arg "IRONCLAW_IMAGE=${IRONCLAW_IMAGE}"
    --build-arg "IRONCLAW_SOURCE_DIGEST=${SOURCE_DIGEST}"
    -t "${IMAGE_REF}"
  )

  if [[ -n "$extra_flag" ]]; then
    args+=("$extra_flag")
  fi

  args+=(.)
  "${args[@]}"
}

echo "Building ${IMAGE_REF} from ${IRONCLAW_IMAGE}..."
set +e
run_build 2>&1 | tee "$BUILD_LOG"
first_exit="${PIPESTATUS[0]}"
set -e

if [[ "$first_exit" -eq 0 ]]; then
  echo "Build succeeded on first attempt."
  exit 0
fi

if grep -Eq "parent snapshot sha256:[a-f0-9]{64} does not exist" "$BUILD_LOG"; then
  echo "Detected orphaned BuildKit snapshot cache entry. Pruning builder cache and retrying once with --no-cache..."
  docker builder prune -af
  run_build --no-cache
  echo "Build succeeded after BuildKit cache reset."
  exit 0
fi

echo "Build failed for a reason other than missing BuildKit parent snapshot cache."
exit "$first_exit"
