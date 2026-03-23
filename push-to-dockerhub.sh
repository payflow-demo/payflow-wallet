#!/bin/bash
# ============================================
# Build and push PayFlow images to Docker Hub
# ============================================
# Usage: ./push-to-dockerhub.sh [your-dockerhub-username] [tag]
#        or set DOCKERHUB_USERNAME and run: ./push-to-dockerhub.sh
# Example: ./push-to-dockerhub.sh veeno
#
# Builds all 6 images with context ./services (so shared/ is included), then
# tags and pushes as <username>/<service>:<tag>.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Username: from argument, or env, or prompt
if [ -n "$1" ]; then
  DOCKERHUB_USERNAME="$1"
elif [ -n "${DOCKERHUB_USERNAME:-}" ]; then
  : # already set
else
  echo "Docker Hub username (e.g. veeno):"
  read -r DOCKERHUB_USERNAME
  if [ -z "$DOCKERHUB_USERNAME" ]; then
    echo "❌ Error: Docker Hub username required"
    echo "Usage: $0 <your-dockerhub-username>"
    echo "   or: DOCKERHUB_USERNAME=veeno $0"
    exit 1
  fi
fi

# Tag: from argument, or env, or git sha + timestamp
if [ -n "${2:-}" ]; then
  DOCKERHUB_TAG="$2"
elif [ -n "${DOCKERHUB_TAG:-}" ]; then
  : # already set
else
  GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || true)"
  TS="$(date +%Y%m%d-%H%M%S)"
  if [ -n "$GIT_SHA" ]; then
    DOCKERHUB_TAG="${GIT_SHA}-${TS}"
  else
    DOCKERHUB_TAG="${TS}"
  fi
fi

echo "🔨 Building and pushing PayFlow images to Docker Hub as: ${DOCKERHUB_USERNAME} (tag: ${DOCKERHUB_TAG})"
echo ""

SERVICES=(api-gateway auth-service wallet-service transaction-service notification-service frontend)

retry() {
  local -r max_attempts="${1:?max_attempts required}"
  local -r base_sleep_seconds="${2:?base_sleep_seconds required}"
  shift 2

  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "❌ Command failed after ${attempt} attempts: $*"
      return 1
    fi

    local sleep_seconds=$(( base_sleep_seconds * attempt ))
    echo "⚠️  Command failed (attempt ${attempt}/${max_attempts}). Retrying in ${sleep_seconds}s..."
    sleep "${sleep_seconds}"
    attempt=$(( attempt + 1 ))
  done
}

# Build each image (context ./services so shared/ is included)
for SVC in "${SERVICES[@]}"; do
  echo "📦 Building $SVC..."
  docker build -t "payflow/${SVC}:${DOCKERHUB_TAG}" -f "services/${SVC}/Dockerfile" ./services
  echo ""
done

# Tag and push each image
for SVC in "${SERVICES[@]}"; do
  NEW_TAG="${DOCKERHUB_USERNAME}/${SVC}:${DOCKERHUB_TAG}"
  echo "⬆️  Pushing $NEW_TAG"
  docker tag "payflow/${SVC}:${DOCKERHUB_TAG}" "$NEW_TAG"
  retry 5 3 docker push "$NEW_TAG"
  echo "   Done: $NEW_TAG"
  echo ""
done

echo "🎉 All images built and pushed to Docker Hub!"
echo ""
echo "Your images:"
for SVC in "${SERVICES[@]}"; do
  echo "  - docker.io/${DOCKERHUB_USERNAME}/${SVC}:${DOCKERHUB_TAG}"
done
