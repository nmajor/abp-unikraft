#!/bin/bash
# Build ABP with stealth patches for Linux x86_64 using Docker.
#
# This runs the entire Chromium build inside a Docker container,
# producing a Linux binary you can deploy to Unikraft.
#
# Works on macOS (Intel or ARM) and Linux hosts.
#
# Prerequisites:
#   - Docker Desktop installed and running
#   - ~120GB free disk space
#   - 16GB+ RAM allocated to Docker (Docker Desktop → Settings → Resources)
#   - Patience (first build: 3-8 hours depending on CPU/cores)
#
# Usage:
#   ./scripts/build-linux-via-docker.sh
#
# Output: ./build-output/abp-stealth-linux-x64.tar.gz
set -euo pipefail

if [ "${ALLOW_LEGACY_ABP_STEALTH:-0}" != "1" ]; then
    echo "ERROR: scripts/build-linux-via-docker.sh is a legacy pre-fingerprint-chromium build path."
    echo "Use scripts/build-on-fp-chromium.sh for all active builds."
    echo "Set ALLOW_LEGACY_ABP_STEALTH=1 only for forensic/reference work."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "============================================================"
echo "  ABP Stealth Build — Linux x64 via Docker"
echo "============================================================"
echo ""
echo "  Make sure Docker has at least 16GB RAM and 120GB disk"
echo "  allocated (Docker Desktop → Settings → Resources)."
echo ""
echo "============================================================"
echo ""

# Create output directory.
OUTPUT_DIR="${PROJECT_DIR}/build-output"
mkdir -p "${OUTPUT_DIR}"

# Build the builder image and run the build.
# We use a Dockerfile that installs all Chromium build deps,
# then runs the build inside the container.
docker build \
    -f "${PROJECT_DIR}/Dockerfile.build" \
    -t abp-stealth-builder \
    "${PROJECT_DIR}"

# Run the build. Mount a named volume for the source tree so it persists
# between builds (makes incremental rebuilds fast).
docker run \
    --rm \
    --name abp-stealth-build \
    -v abp-chromium-src:/build \
    -v "${PROJECT_DIR}/patches:/patches:ro" \
    -v "${PROJECT_DIR}/src:/stealth-src:ro" \
    -v "${PROJECT_DIR}/scripts:/scripts:ro" \
    -v "${OUTPUT_DIR}:/output" \
    -e "NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)" \
    abp-stealth-builder

echo ""
echo "============================================================"
echo "  BUILD COMPLETE"
echo "============================================================"
echo ""
echo "  Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
echo ""
echo "  To deploy to Unikraft, update the Dockerfile to use this"
echo "  binary instead of the pre-built one from GitHub Releases."
echo "============================================================"
