#!/bin/bash
# End-to-end build script for ABP with stealth patches on macOS (Intel).
#
# Prerequisites:
#   - macOS with Xcode installed (xcode-select --install)
#   - ~120GB free disk space
#   - 16GB+ RAM recommended
#   - Several hours for first build (incremental rebuilds are minutes)
#
# Usage:
#   ./scripts/build-local-mac.sh [/path/to/workspace]
#
# Default workspace: ~/aspect-stealth-build
set -euo pipefail

if [ "${ALLOW_LEGACY_ABP_STEALTH:-0}" != "1" ]; then
    echo "ERROR: scripts/build-local-mac.sh is a legacy pre-fingerprint-chromium build path."
    echo "Use scripts/build-on-fp-chromium.sh for all active builds."
    echo "Set ALLOW_LEGACY_ABP_STEALTH=1 only for forensic/reference work."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORKSPACE="${1:-$HOME/abp-stealth-build}"

echo "============================================================"
echo "  ABP Stealth Build — macOS Intel"
echo "============================================================"
echo ""
echo "  Workspace: ${WORKSPACE}"
echo "  Patches:   ${PROJECT_DIR}/patches/"
echo "  Source:     ${PROJECT_DIR}/src/"
echo ""
echo "  This will use ~120GB of disk space."
echo "  First build takes 2-6 hours depending on your CPU."
echo "============================================================"
echo ""

# -------------------------------------------------------------------
# Step 0: Check prerequisites
# -------------------------------------------------------------------
echo "==> Step 0: Checking prerequisites"

if ! xcode-select -p &>/dev/null; then
    echo "ERROR: Xcode command line tools not installed."
    echo "Run: xcode-select --install"
    exit 1
fi
echo "  Xcode: OK"

# Check disk space (need ~120GB)
AVAILABLE_GB=$(df -g "${WORKSPACE%/*}" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
if [ "${AVAILABLE_GB}" -lt 100 ] 2>/dev/null; then
    echo "WARNING: Only ${AVAILABLE_GB}GB free. Recommend 120GB+."
    echo "Continue anyway? (y/n)"
    read -r REPLY
    [ "$REPLY" != "y" ] && exit 1
fi
echo "  Disk: ${AVAILABLE_GB}GB available"

# Check RAM
RAM_GB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1073741824}')
echo "  RAM: ${RAM_GB}GB"

CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "4")
echo "  CPU cores: ${CORES}"
echo ""

# -------------------------------------------------------------------
# Step 1: Install depot_tools (Chromium's build toolchain)
# -------------------------------------------------------------------
echo "==> Step 1: Setting up depot_tools"

DEPOT_TOOLS="${WORKSPACE}/depot_tools"
if [ ! -d "${DEPOT_TOOLS}" ]; then
    mkdir -p "${WORKSPACE}"
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT_TOOLS}"
    echo "  Cloned depot_tools"
else
    echo "  depot_tools already exists, updating..."
    cd "${DEPOT_TOOLS}" && git pull
fi
export PATH="${DEPOT_TOOLS}:${PATH}"
echo "  depot_tools in PATH"
echo ""

# -------------------------------------------------------------------
# Step 2: Fetch ABP source (or update existing)
# -------------------------------------------------------------------
echo "==> Step 2: Fetching ABP Chromium source"

SRC_DIR="${WORKSPACE}/src"
if [ ! -d "${SRC_DIR}/chrome/browser/abp" ]; then
    mkdir -p "${WORKSPACE}"
    cd "${WORKSPACE}"

    echo "  Creating gclient config for ABP..."
    cat > .gclient << 'GCLIENT'
solutions = [
  {
    "name": "src",
    "url": "https://github.com/theredsix/agent-browser-protocol.git@dev",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {},
  },
]
GCLIENT

    echo "  Running gclient sync (this downloads ~7GB, expands to ~30GB)..."
    echo "  This is the longest step on first run. Go grab a coffee."
    echo ""
    gclient sync --no-history --nohooks -j "${CORES}"

    echo "  Running hooks..."
    gclient runhooks
    echo "  Source sync complete."
else
    echo "  ABP source already exists at ${SRC_DIR}"
    echo "  Running gclient sync for updates..."
    cd "${WORKSPACE}"
    gclient sync --no-history -j "${CORES}"
fi
echo ""

# -------------------------------------------------------------------
# Step 3: Apply stealth patches
# -------------------------------------------------------------------
echo "==> Step 3: Applying stealth patches"

"${SCRIPT_DIR}/apply-patches.sh" "${SRC_DIR}"
echo ""

# -------------------------------------------------------------------
# Step 4: Generate build configuration
# -------------------------------------------------------------------
echo "==> Step 4: Generating build files (GN)"

BUILD_DIR="${SRC_DIR}/out/Release"
cd "${SRC_DIR}"

# macOS Intel build args.
cat > "${BUILD_DIR}_args.gn" << 'GNARGS'
is_debug = false
is_component_build = false
symbol_level = 0
is_official_build = true
chrome_pgo_phase = 0
target_cpu = "x64"
enable_nacl = false
blink_symbol_level = 0
GNARGS

mkdir -p "${BUILD_DIR}"
cp "${BUILD_DIR}_args.gn" "${BUILD_DIR}/args.gn"
gn gen "${BUILD_DIR}"
echo "  Build configured."
echo ""

# -------------------------------------------------------------------
# Step 5: Build
# -------------------------------------------------------------------
echo "==> Step 5: Building Chrome (using ${CORES} cores)"
echo "  This will take a while on first build..."
echo "  You can monitor progress — ninja shows [X/Y] completed targets."
echo ""

autoninja -C "${BUILD_DIR}" chrome

echo ""
echo "  Build complete!"
echo ""

# -------------------------------------------------------------------
# Step 6: Verify the build
# -------------------------------------------------------------------
echo "==> Step 6: Verifying build"

ABP_BINARY="${BUILD_DIR}/abp"
if [ ! -f "${ABP_BINARY}" ]; then
    # On macOS the binary might be inside an app bundle.
    ABP_BINARY="${BUILD_DIR}/Chromium.app/Contents/MacOS/Chromium"
    if [ ! -f "${ABP_BINARY}" ]; then
        echo "WARNING: Could not find ABP binary. Check ${BUILD_DIR} manually."
        echo "Listing candidates:"
        find "${BUILD_DIR}" -maxdepth 2 -name "abp" -o -name "chrome" -o -name "Chromium" 2>/dev/null | head -5
        exit 1
    fi
fi

echo "  Binary: ${ABP_BINARY}"
echo "  Size: $(du -h "${ABP_BINARY}" | cut -f1)"
echo ""

# Quick smoke test.
echo "  Running smoke test (headless, 5 second timeout)..."
timeout 10 "${ABP_BINARY}" \
    --headless=new \
    --no-sandbox \
    --disable-gpu \
    --abp-port=19222 \
    --abp-fingerprint=42 \
    --user-data-dir=$(mktemp -d) &
ABP_PID=$!
sleep 5

if curl -s --max-time 3 http://localhost:19222/api/v1/browser/status | grep -q '"ready":true'; then
    echo "  Smoke test PASSED — ABP is responding with stealth flags."
else
    echo "  Smoke test: ABP did not respond (may need more time to start)."
fi
kill "${ABP_PID}" 2>/dev/null || true
wait "${ABP_PID}" 2>/dev/null || true
echo ""

# -------------------------------------------------------------------
# Step 7: Package for Linux (cross-compile or package macOS)
# -------------------------------------------------------------------
echo "==> Step 7: Packaging"

if [ -f "${SRC_DIR}/tools/abp/package-mac.sh" ]; then
    echo "  Running ABP's macOS packaging script..."
    "${SRC_DIR}/tools/abp/package-mac.sh" || echo "  (packaging script had issues, check manually)"
else
    echo "  No packaging script found. The binary is at:"
    echo "  ${ABP_BINARY}"
fi

echo ""
echo "============================================================"
echo "  BUILD COMPLETE"
echo "============================================================"
echo ""
echo "  Binary: ${ABP_BINARY}"
echo "  Workspace: ${WORKSPACE}"
echo ""
echo "  To rebuild after patch changes (fast, minutes):"
echo "    cd ${SRC_DIR} && autoninja -C out/Release chrome"
echo ""
echo "  To test with stealth:"
echo "    ${ABP_BINARY} --abp-fingerprint=42 --headless=new --no-sandbox --abp-port=15678"
echo ""
echo "  NOTE: This built a macOS binary. For Unikraft (Linux), you need"
echo "  to build on a Linux machine or cross-compile. Options:"
echo "    1. Run this same process on a Linux VM"
echo "    2. Use the Linux build script: scripts/build-abp-stealth.sh"
echo "============================================================"
