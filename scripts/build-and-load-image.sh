#!/usr/bin/env bash
# Build the Biashara OS image with Podman, export it as a docker-archive, and
# import it into the worker node's containerd store so kubelet (which uses
# containerd, not podman) can run it with imagePullPolicy: Never.
#
# Run this on the worker node `deploy`.
#
# Env overrides:
#   VERSION   image tag (default 0.2.0)
#   SRC_DIR   path to the Biashara OS source checkout (default ~/biasharaos)
set -euo pipefail

VERSION="${VERSION:-0.2.0}"
SRC_DIR="${SRC_DIR:-$HOME/biasharaos}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCKERFILE="$REPO_DIR/app/Dockerfile"
TAR="/tmp/biasharaos-${VERSION}.tar"
IMAGE="localhost/biasharaos:${VERSION}"

if [ ! -d "$SRC_DIR" ]; then
  echo "Source checkout not found at $SRC_DIR. Clone it or set SRC_DIR."
  exit 1
fi
if [ ! -f "$DOCKERFILE" ]; then
  echo "Dockerfile not found at $DOCKERFILE"
  exit 1
fi

echo "--- syntax check ---"
( cd "$SRC_DIR" && node --check backend/server.js )

echo "--- podman build $IMAGE ---"
podman build -t "$IMAGE" -f "$DOCKERFILE" "$SRC_DIR"

echo "--- podman save -> $TAR ---"
podman save --format docker-archive -o "$TAR" "$IMAGE"

echo "--- import into containerd (k8s.io namespace) ---"
sudo ctr -n k8s.io images import "$TAR"
sudo ctr -n k8s.io images list | grep biasharaos || true

echo
echo "Image $IMAGE loaded on this node's containerd. Now:"
echo "  kubectl set image deployment/biasharaos biasharaos=$IMAGE -n biasharaos"
echo "  kubectl rollout status deployment/biasharaos -n biasharaos --timeout=180s"
