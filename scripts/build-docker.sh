#!/bin/bash
# Build the Docker image containing ABP + all dependencies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME="${IMAGE_NAME:-abp-unikraft}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

echo "==> Building Docker image: ${IMAGE_NAME}:${IMAGE_TAG}"
docker build \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    -f "${PROJECT_DIR}/Dockerfile" \
    "${PROJECT_DIR}"

echo "==> Docker image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"
