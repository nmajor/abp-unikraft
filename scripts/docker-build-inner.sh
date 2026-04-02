#!/bin/bash
# Runs INSIDE the Docker container. Do not run directly.
set -euo pipefail

NPROC="${NPROC:-4}"
WORKSPACE="/build"

echo "============================================================"
echo "  Building ABP Stealth (Linux x64) — ${NPROC} cores"
echo "============================================================"

# -------------------------------------------------------------------
# Step 1: depot_tools
# -------------------------------------------------------------------
DEPOT_TOOLS="${WORKSPACE}/depot_tools"
if [ ! -d "${DEPOT_TOOLS}" ]; then
    echo "==> Installing depot_tools..."
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT_TOOLS}"
else
    echo "==> Updating depot_tools..."
    cd "${DEPOT_TOOLS}" && git pull
fi
export PATH="${DEPOT_TOOLS}:${PATH}"

# -------------------------------------------------------------------
# Step 2: Fetch/update ABP source
# -------------------------------------------------------------------
SRC_DIR="${WORKSPACE}/src"
cd "${WORKSPACE}"

if [ ! -d "${SRC_DIR}/chrome/browser/abp" ]; then
    echo "==> First run: fetching ABP source (this takes 10-30 min)..."

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

    gclient sync --no-history --nohooks -j "${NPROC}"
    cd "${SRC_DIR}"

    # Run Chromium's install-build-deps.sh for any missing system deps.
    if [ -f "build/install-build-deps.sh" ]; then
        echo "==> Running install-build-deps.sh..."
        sudo bash build/install-build-deps.sh --no-prompt --no-chromeos-fonts --no-arm --no-nacl || true
    fi

    cd "${WORKSPACE}"
    gclient runhooks
else
    echo "==> Source exists, running gclient sync for updates..."
    gclient sync --no-history -j "${NPROC}"
fi

# -------------------------------------------------------------------
# Step 3: Copy stealth source files
# -------------------------------------------------------------------
echo "==> Copying stealth source files..."
STEALTH_DEST="${SRC_DIR}/chrome/browser/abp/stealth"
mkdir -p "${STEALTH_DEST}"
cp -v /stealth-src/chrome/browser/abp/stealth/* "${STEALTH_DEST}/"

# -------------------------------------------------------------------
# Step 4: Apply patches
# -------------------------------------------------------------------
echo "==> Applying stealth patches..."
SERIES_FILE="/patches/series"
cd "${SRC_DIR}"

APPLIED=0
SKIPPED=0

while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" =~ ^# ]] && continue
    PATCH_FILE="/patches/${patch_name}"
    [ ! -f "${PATCH_FILE}" ] && continue

    echo -n "  ${patch_name}... "
    if git apply --check "${PATCH_FILE}" 2>/dev/null; then
        git apply "${PATCH_FILE}"
        echo "applied"
        APPLIED=$((APPLIED + 1))
    elif git apply --check --reverse "${PATCH_FILE}" 2>/dev/null; then
        echo "already applied"
        SKIPPED=$((SKIPPED + 1))
    else
        echo "NEEDS MANUAL ADAPTATION — see patch Description header"
        SKIPPED=$((SKIPPED + 1))
    fi
done < "${SERIES_FILE}"

echo "  Applied: ${APPLIED}, Skipped: ${SKIPPED}"

# Apply feature edits (bandwidth metering + full page screenshot).
# Scripts are mounted at /scripts in the Docker container.
echo "==> Applying feature edits..."
if [ -f "/scripts/apply-feature-edits.sh" ]; then
    bash "/scripts/apply-feature-edits.sh" "${SRC_DIR}"
else
    echo "  WARN: apply-feature-edits.sh not found, skipping feature edits"
fi

# -------------------------------------------------------------------
# Step 5: Build
# -------------------------------------------------------------------
echo "==> Configuring build..."
BUILD_DIR="${SRC_DIR}/out/Release"
mkdir -p "${BUILD_DIR}"

cat > "${BUILD_DIR}/args.gn" << 'GNARGS'
is_debug = false
is_component_build = false
symbol_level = 0
is_official_build = true
chrome_pgo_phase = 0
target_cpu = "x64"
enable_nacl = false
blink_symbol_level = 0
GNARGS

gn gen "${BUILD_DIR}"

echo "==> Building (${NPROC} cores)... this will take a while."
autoninja -C "${BUILD_DIR}" -j "${NPROC}" chrome

# -------------------------------------------------------------------
# Step 6: Package
# -------------------------------------------------------------------
echo "==> Packaging..."
PACKAGE_DIR=$(mktemp -d)
ABP_OUT="${PACKAGE_DIR}/abp-chrome"
mkdir -p "${ABP_OUT}"

# Copy binary and required files (following ABP's package-linux.sh pattern).
cd "${BUILD_DIR}"
cp -a abp "${ABP_OUT}/" 2>/dev/null || cp -a chrome "${ABP_OUT}/abp" 2>/dev/null || true
cp -a chrome_crashpad_handler "${ABP_OUT}/" 2>/dev/null || true
cp -a *.so* "${ABP_OUT}/" 2>/dev/null || true
cp -a *.pak "${ABP_OUT}/" 2>/dev/null || true
cp -a icudtl.dat "${ABP_OUT}/" 2>/dev/null || true
cp -a v8_context_snapshot.bin "${ABP_OUT}/" 2>/dev/null || true
cp -a snapshot_blob.bin "${ABP_OUT}/" 2>/dev/null || true
cp -ra locales "${ABP_OUT}/" 2>/dev/null || true
cp -a vk_swiftshader_icd.json "${ABP_OUT}/" 2>/dev/null || true
cp -ra lib "${ABP_OUT}/" 2>/dev/null || true

# Create tarball.
OUTPUT_NAME="abp-stealth-linux-x64.tar.gz"
cd "${PACKAGE_DIR}"
tar -czf "/output/${OUTPUT_NAME}" abp-chrome/
rm -rf "${PACKAGE_DIR}"

echo ""
echo "============================================================"
echo "  BUILD COMPLETE"
echo "============================================================"
echo "  Output: /output/${OUTPUT_NAME}"
ls -lh "/output/${OUTPUT_NAME}"
echo ""
echo "  This binary has stealth patches baked in."
echo "  Use it with: abp --abp-fingerprint=42 --headless=new"
echo "============================================================"
