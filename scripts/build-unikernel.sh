#!/bin/bash
# Build the full unikernel: Docker image -> rootfs export -> EROFS initrd -> kraft pkg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

IMAGE_NAME="${IMAGE_NAME:-abp-unikraft}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
CONTAINER_NAME="abp-unikraft-export"
ROOTFS_DIR="${PROJECT_DIR}/.rootfs"
INITRD_PATH="${PROJECT_DIR}/initrd"

# Step 1: Build Docker image
echo "==> Step 1: Building Docker image..."
"${SCRIPT_DIR}/build-docker.sh"

# Step 2: Export container filesystem
echo "==> Step 2: Exporting container filesystem..."
rm -rf "${ROOTFS_DIR}"
mkdir -p "${ROOTFS_DIR}"

# Create a container (don't start it) and export its filesystem
docker create --name "${CONTAINER_NAME}" "${IMAGE_NAME}:${IMAGE_TAG}" || true
docker export "${CONTAINER_NAME}" | tar -x -C "${ROOTFS_DIR}"
docker rm "${CONTAINER_NAME}" || true

echo "    Rootfs exported to ${ROOTFS_DIR}"
echo "    Size: $(du -sh "${ROOTFS_DIR}" | cut -f1)"

# Step 3: Create EROFS initrd
echo "==> Step 3: Creating EROFS initrd..."

# Install mkfs.erofs if not available
if ! command -v mkfs.erofs &> /dev/null; then
    echo "    Installing erofs-utils..."
    sudo apt-get update && sudo apt-get install -y erofs-utils
fi

rm -f "${INITRD_PATH}"
mkfs.erofs \
    --all-root \
    -d2 \
    -E noinline_data \
    -b 4096 \
    "${INITRD_PATH}" \
    "${ROOTFS_DIR}"

echo "    Initrd created: ${INITRD_PATH}"
echo "    Size: $(du -sh "${INITRD_PATH}" | cut -f1)"

# Step 4: Package with kraft
echo "==> Step 4: Packaging with kraft..."
cd "${PROJECT_DIR}"
kraft pkg --name abp-unikraft --strategy overwrite

echo ""
echo "==> Build complete!"
echo "    To deploy: kraft cloud deploy --metro fra0 -p 443:15678 -M 4096 ."
