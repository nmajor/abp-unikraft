#!/bin/bash
# ONE SCRIPT TO RULE THEM ALL.
#
# Paste this into a fresh Hetzner Ubuntu 22.04 server (CCX33 or bigger).
# It does everything: installs deps, fetches source, applies patches,
# builds Chromium, packages the binary, uploads it as a GitHub Release,
# then prints instructions to delete the server.
#
# Create a Hetzner server:
#   1. Go to https://console.hetzner.cloud
#   2. Create server → Location: your choice → Image: Ubuntu 22.04
#   3. Type: CCX33 (16 dedicated vCPU, 64GB RAM, ~€0.30/hr)
#         or CCX63 (48 dedicated vCPU, 192GB RAM, ~€0.46/hr) for 3x faster
#   4. SSH key: add yours
#   5. Create & Buy
#
# Then SSH in and run:
#   curl -sL https://raw.githubusercontent.com/YOUR_USER/abp-unikraft/main/scripts/build-on-hetzner.sh | bash
#
# Or paste the whole script. It's self-contained.
#
# Cost: CCX33 for ~4hrs = ~€1.20. CCX63 for ~2hrs = ~€0.92.
set -euo pipefail

REPO="nmajor/abp-unikraft"
BRANCH="main"
BUILD_DIR="/root/build"
NPROC=$(nproc)

echo "============================================================"
echo "  ABP Stealth Chromium Build"
echo "  $(date)"
echo "  Cores: ${NPROC}  RAM: $(free -h | awk '/Mem:/{print $2}')"
echo "============================================================"

# -------------------------------------------------------------------
# Step 1: System dependencies
# -------------------------------------------------------------------
echo ""
echo "==> [1/8] Installing system dependencies..."
apt-get update
apt-get install -y \
    build-essential clang cmake curl git gperf lld \
    libcups2-dev libdrm-dev libgbm-dev libgtk-3-dev libkrb5-dev \
    libnss3-dev libpango1.0-dev libpulse-dev libudev-dev libva-dev \
    libxcomposite-dev libxdamage-dev libxrandr-dev libxshmfence-dev \
    lsb-release ninja-build pkg-config python3 python3-pip \
    sudo wget xz-utils file

# Install gh CLI
if ! command -v gh &>/dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update && apt-get install -y gh
fi

echo "  Done."

# -------------------------------------------------------------------
# Step 2: Authenticate GitHub
# -------------------------------------------------------------------
echo ""
echo "==> [2/8] GitHub authentication"
if ! gh auth status &>/dev/null; then
    echo "  Please authenticate with GitHub to upload the release."
    echo "  Run: gh auth login"
    echo "  (Choose HTTPS, paste a personal access token with 'repo' scope)"
    gh auth login
fi
echo "  Authenticated as: $(gh api user -q .login)"

# -------------------------------------------------------------------
# Step 3: Clone our patches repo
# -------------------------------------------------------------------
echo ""
echo "==> [3/8] Cloning patch repo..."
PATCH_REPO="/root/abp-unikraft"
if [ ! -d "${PATCH_REPO}" ]; then
    gh repo clone "${REPO}" "${PATCH_REPO}" -- --branch "${BRANCH}"
else
    cd "${PATCH_REPO}" && git pull
fi
echo "  Patches at: ${PATCH_REPO}"

# -------------------------------------------------------------------
# Step 4: depot_tools + ABP source
# -------------------------------------------------------------------
echo ""
echo "==> [4/8] Setting up depot_tools and fetching ABP source..."

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# depot_tools
if [ ! -d "depot_tools" ]; then
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="${BUILD_DIR}/depot_tools:${PATH}"

# depot_tools refuses to bootstrap as root ("Running depot tools as root is sad").
# The ensure_bootstrap script does the same work WITHOUT the root check.
# It downloads the CIPD-managed Python 3, gn, ninja, etc.
export DEPOT_TOOLS_UPDATE=0
echo "  Bootstrapping depot_tools (bypassing root check)..."
cd "${BUILD_DIR}/depot_tools"
./ensure_bootstrap
cd "${BUILD_DIR}"

# Verify bootstrap worked
if [ ! -f "${BUILD_DIR}/depot_tools/python3_bin_reldir.txt" ]; then
    echo "ERROR: depot_tools bootstrap failed. python3_bin_reldir.txt not created."
    exit 1
fi
echo "  depot_tools bootstrapped OK."

# ABP source
if [ ! -d "src/chrome/browser/abp" ]; then
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

    echo "  Fetching ABP source (this takes 15-30 min)..."
    gclient sync --no-history --nohooks -j "${NPROC}"

    cd src
    echo "  Running install-build-deps.sh..."
    sudo bash build/install-build-deps.sh --no-prompt --no-chromeos-fonts --no-arm --no-nacl || true
    cd "${BUILD_DIR}"

    gclient runhooks
    echo "  Source fetched."
else
    echo "  Source already exists, syncing..."
    gclient sync --no-history -j "${NPROC}"
fi

SRC_DIR="${BUILD_DIR}/src"

# -------------------------------------------------------------------
# Step 5: Copy stealth files + apply patches
# -------------------------------------------------------------------
echo ""
echo "==> [5/8] Applying stealth edits..."

# Copy stealth source files.
STEALTH_DEST="${SRC_DIR}/chrome/browser/abp/stealth"
mkdir -p "${STEALTH_DEST}"
cp -v "${PATCH_REPO}/src/chrome/browser/abp/stealth/"* "${STEALTH_DEST}/"

# Apply source edits (sed/python based — more robust than git apply).
chmod +x "${PATCH_REPO}/scripts/apply-stealth-edits.sh"
bash "${PATCH_REPO}/scripts/apply-stealth-edits.sh" "${SRC_DIR}"

# Apply feature edits (bandwidth metering + full page screenshot).
chmod +x "${PATCH_REPO}/scripts/apply-feature-edits.sh"
bash "${PATCH_REPO}/scripts/apply-feature-edits.sh" "${SRC_DIR}"

# -------------------------------------------------------------------
# Step 6: Configure + Build
# -------------------------------------------------------------------
echo ""
echo "==> [6/8] Configuring and building..."
echo "  Build started at: $(date)"

RELEASE_DIR="${SRC_DIR}/out/Release"
mkdir -p "${RELEASE_DIR}"
cat > "${RELEASE_DIR}/args.gn" << 'GNARGS'
is_debug = false
is_component_build = false
symbol_level = 0
is_official_build = true
chrome_pgo_phase = 0
target_cpu = "x64"
enable_nacl = false
blink_symbol_level = 0
GNARGS

cd "${SRC_DIR}"
gn gen "${RELEASE_DIR}"

echo "  Building with ${NPROC} cores..."
autoninja -C "${RELEASE_DIR}" -j "${NPROC}" chrome

echo "  Build finished at: $(date)"

# -------------------------------------------------------------------
# Step 7: Package
# -------------------------------------------------------------------
echo ""
echo "==> [7/8] Packaging..."

PKG_DIR=$(mktemp -d)
ABP_OUT="${PKG_DIR}/abp-chrome"
mkdir -p "${ABP_OUT}"
cd "${RELEASE_DIR}"

for f in abp chrome chrome_crashpad_handler vk_swiftshader_icd.json \
         icudtl.dat v8_context_snapshot.bin snapshot_blob.bin; do
    [ -f "$f" ] && cp -a "$f" "${ABP_OUT}/"
done
cp -a *.so* "${ABP_OUT}/" 2>/dev/null || true
cp -a *.pak "${ABP_OUT}/" 2>/dev/null || true
cp -ra locales "${ABP_OUT}/" 2>/dev/null || true
cp -ra lib "${ABP_OUT}/" 2>/dev/null || true

# Rename chrome → abp if needed
[ -f "${ABP_OUT}/chrome" ] && [ ! -f "${ABP_OUT}/abp" ] && mv "${ABP_OUT}/chrome" "${ABP_OUT}/abp"
[ -f "${ABP_OUT}/abp" ] && chmod +x "${ABP_OUT}/abp"

OUTPUT="/root/abp-stealth-linux-x64.tar.gz"
cd "${PKG_DIR}"
tar -czf "${OUTPUT}" abp-chrome/
rm -rf "${PKG_DIR}"

echo "  Package: ${OUTPUT}"
echo "  Size: $(du -h "${OUTPUT}" | cut -f1)"

# -------------------------------------------------------------------
# Step 8: Upload to GitHub Release
# -------------------------------------------------------------------
echo ""
echo "==> [8/8] Uploading to GitHub Release..."

VERSION="stealth-$(date +%Y%m%d-%H%M%S)"

gh release create "${VERSION}" \
    --repo "${REPO}" \
    --title "ABP Stealth Build ${VERSION}" \
    --notes "ABP Chromium with C++ stealth patches. Built on Hetzner CCX (${NPROC} cores)." \
    "${OUTPUT}#abp-stealth-linux-x64.tar.gz"

RELEASE_URL="https://github.com/${REPO}/releases/tag/${VERSION}"

echo ""
echo "============================================================"
echo "  ALL DONE!"
echo "  $(date)"
echo "============================================================"
echo ""
echo "  Release: ${RELEASE_URL}"
echo "  Binary:  abp-stealth-linux-x64.tar.gz"
echo ""
echo "  Next steps:"
echo "    1. Update Dockerfile to download from this release"
echo "    2. Push to trigger KraftCloud image rebuild"
echo "    3. DELETE THIS SERVER to stop billing:"
echo "       Go to Hetzner Console → Servers → Delete"
echo ""
echo "  Auto-powering off in 60 seconds to minimize costs..."
echo "  (Hetzner still bills for powered-off servers — DELETE it!)"
echo "============================================================"

# Auto-poweroff to minimize costs if user walks away.
# NOTE: Hetzner bills for powered-off servers. You must DELETE it.
sleep 60
poweroff
