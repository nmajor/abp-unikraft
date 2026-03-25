#!/bin/bash
# Full build pipeline for ABP with stealth patches.
#
# Prerequisites:
#   - Chromium depot_tools in PATH
#   - ABP source tree already fetched (gclient sync done)
#   - ~100GB disk space, ~16GB RAM
#
# Usage: ./scripts/build-abp-stealth.sh /path/to/abp-chromium-src
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [ $# -lt 1 ]; then
    echo "Usage: $0 /path/to/abp-chromium-src"
    exit 1
fi

CHROMIUM_SRC="$1"
BUILD_DIR="${CHROMIUM_SRC}/out/Release"

echo "============================================"
echo "  ABP Stealth Build"
echo "============================================"
echo ""

# Step 1: Apply stealth patches.
echo "==> Step 1: Applying stealth patches"
"${SCRIPT_DIR}/apply-patches.sh" "${CHROMIUM_SRC}"

# Step 2: Generate build files.
echo ""
echo "==> Step 2: Generating build files (GN)"
cd "${CHROMIUM_SRC}"

GN_ARGS='
is_debug=false
is_component_build=false
symbol_level=0
is_official_build=true
chrome_pgo_phase=0
'

gn gen "${BUILD_DIR}" --args="${GN_ARGS}"

# Step 3: Build.
echo ""
echo "==> Step 3: Building Chrome (this will take a while...)"
autoninja -C "${BUILD_DIR}" chrome

echo ""
echo "==> Step 4: Packaging"
# Use ABP's existing packaging script if available.
if [ -f "${CHROMIUM_SRC}/tools/abp/package-linux.sh" ]; then
    "${CHROMIUM_SRC}/tools/abp/package-linux.sh"
else
    echo "Package manually from ${BUILD_DIR}/abp"
fi

echo ""
echo "============================================"
echo "  Build complete!"
echo "============================================"
echo ""
echo "The stealth-enabled ABP binary is at: ${BUILD_DIR}/abp"
echo ""
echo "Test with:"
echo "  ${BUILD_DIR}/abp --abp-fingerprint=42 --headless=new --no-sandbox"
echo ""
echo "Or with full stealth:"
echo "  ${BUILD_DIR}/abp \\"
echo "    --abp-fingerprint=42 \\"
echo "    --abp-fingerprint-platform=windows \\"
echo "    --abp-timezone=America/New_York \\"
echo "    --headless=new \\"
echo "    --no-sandbox \\"
echo "    --abp-port=15678"
