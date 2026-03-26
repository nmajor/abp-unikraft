#!/bin/bash
# Build ABP with stealth patches on Fly.io.
#
# Run this from your local machine (macOS/Linux) with the fly CLI installed.
# It creates a Fly Machine, builds Chromium, uploads the binary as a
# GitHub Release, then destroys the machine.
#
# Prerequisites:
#   - fly CLI installed and authenticated (fly auth login)
#   - gh CLI installed and authenticated (gh auth login)
#   - You're in the abp-unikraft repo directory
#
# Cost: ~$4-8 depending on build time (performance-16x, 32GB RAM)
#
# Usage:
#   ./scripts/build-on-fly.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

APP_NAME="abp-stealth-builder"
REGION="iad"  # US East — change if you prefer another region
VOLUME_NAME="abp-build-vol"
VOLUME_SIZE="200"  # GB
MACHINE_SIZE="performance-16x"
MACHINE_RAM="32768"  # 32GB in MB

echo "============================================================"
echo "  ABP Stealth Build on Fly.io"
echo "============================================================"
echo ""
echo "  Machine: ${MACHINE_SIZE} (16 vCPU, 32GB RAM)"
echo "  Volume:  ${VOLUME_SIZE}GB"
echo "  Region:  ${REGION}"
echo "  Est. cost: ~$4-8 for first build, ~$1-2 for rebuilds"
echo ""
echo "============================================================"
echo ""

# -------------------------------------------------------------------
# Step 1: Get GitHub token for uploading the release
# -------------------------------------------------------------------
echo "==> Step 1: Getting GitHub token"
GH_TOKEN=$(gh auth token)
if [ -z "${GH_TOKEN}" ]; then
    echo "ERROR: Not authenticated with gh CLI. Run: gh auth login"
    exit 1
fi
GH_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
if [ -z "${GH_REPO}" ]; then
    echo "ERROR: Not in a GitHub repo. Run from the abp-unikraft directory."
    exit 1
fi
echo "  GitHub repo: ${GH_REPO}"
echo "  Token: ${GH_TOKEN:0:10}..."
echo ""

# -------------------------------------------------------------------
# Step 2: Create Fly app (if not exists)
# -------------------------------------------------------------------
echo "==> Step 2: Setting up Fly app"
if ! fly apps list 2>/dev/null | grep -q "${APP_NAME}"; then
    fly apps create "${APP_NAME}" --org personal 2>/dev/null || true
    echo "  Created app: ${APP_NAME}"
else
    echo "  App already exists: ${APP_NAME}"
fi
echo ""

# -------------------------------------------------------------------
# Step 3: Create volume (if not exists)
# -------------------------------------------------------------------
echo "==> Step 3: Setting up build volume"
EXISTING_VOL=$(fly volumes list -a "${APP_NAME}" --json 2>/dev/null | python3 -c "
import sys, json
vols = json.load(sys.stdin)
for v in vols:
    if v.get('name') == '${VOLUME_NAME}' and v.get('region') == '${REGION}':
        print(v['id'])
        break
" 2>/dev/null || echo "")

if [ -z "${EXISTING_VOL}" ]; then
    echo "  Creating ${VOLUME_SIZE}GB volume in ${REGION}..."
    EXISTING_VOL=$(fly volumes create "${VOLUME_NAME}" \
        --app "${APP_NAME}" \
        --region "${REGION}" \
        --size "${VOLUME_SIZE}" \
        --yes \
        --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    echo "  Created volume: ${EXISTING_VOL}"
else
    echo "  Reusing existing volume: ${EXISTING_VOL}"
    echo "  (Incremental build — will be much faster!)"
fi
echo ""

# -------------------------------------------------------------------
# Step 4: Build and push the builder Docker image to Fly
# -------------------------------------------------------------------
echo "==> Step 4: Building builder Docker image"
cd "${PROJECT_DIR}"

# Create a combined Dockerfile that has everything needed.
cat > /tmp/Dockerfile.fly-build << 'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install Chromium build dependencies.
RUN apt-get update && apt-get install -y \
    build-essential \
    clang \
    cmake \
    curl \
    git \
    gperf \
    lld \
    libcups2-dev \
    libdrm-dev \
    libgbm-dev \
    libgtk-3-dev \
    libkrb5-dev \
    libnss3-dev \
    libpango1.0-dev \
    libpulse-dev \
    libudev-dev \
    libva-dev \
    libxcomposite-dev \
    libxdamage-dev \
    libxrandr-dev \
    libxshmfence-dev \
    lsb-release \
    ninja-build \
    pkg-config \
    python3 \
    python3-pip \
    sudo \
    wget \
    xz-utils \
    file \
    && rm -rf /var/lib/apt/lists/*

# Install gh CLI for uploading releases.
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/docker-build-inner.sh /build-inner.sh
COPY scripts/apply-patches.sh /apply-patches.sh
COPY patches/ /patches/
COPY src/ /stealth-src/
RUN chmod +x /build-inner.sh /apply-patches.sh

COPY scripts/fly-build-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
DOCKERFILE

# Create the entrypoint that runs the build AND uploads.
cat > "${PROJECT_DIR}/scripts/fly-build-entrypoint.sh" << 'ENTRYPOINT'
#!/bin/bash
set -euo pipefail

echo "============================================================"
echo "  ABP Stealth Build — Fly.io Machine"
echo "  Started at: $(date)"
echo "============================================================"

NPROC="${NPROC:-16}"
WORKSPACE="/build"
GH_TOKEN="${GH_TOKEN:-}"
GH_REPO="${GH_REPO:-}"

# -------------------------------------------------------------------
# Build (reuse docker-build-inner.sh logic but inline for clarity)
# -------------------------------------------------------------------

# depot_tools
DEPOT_TOOLS="${WORKSPACE}/depot_tools"
if [ ! -d "${DEPOT_TOOLS}" ]; then
    echo "==> Installing depot_tools..."
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT_TOOLS}"
else
    echo "==> depot_tools exists"
fi
export PATH="${DEPOT_TOOLS}:${PATH}"

# Fetch ABP source
SRC_DIR="${WORKSPACE}/src"
cd "${WORKSPACE}"

if [ ! -d "${SRC_DIR}/chrome/browser/abp" ]; then
    echo "==> First run: fetching ABP source (~20-40 min)..."
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
    if [ -f "build/install-build-deps.sh" ]; then
        echo "==> Running install-build-deps.sh..."
        sudo bash build/install-build-deps.sh --no-prompt --no-chromeos-fonts --no-arm --no-nacl || true
    fi
    cd "${WORKSPACE}"
    gclient runhooks
else
    echo "==> Source exists, syncing updates..."
    gclient sync --no-history -j "${NPROC}"
fi

# Copy stealth files
echo "==> Copying stealth source files..."
STEALTH_DEST="${SRC_DIR}/chrome/browser/abp/stealth"
mkdir -p "${STEALTH_DEST}"
cp -v /stealth-src/chrome/browser/abp/stealth/* "${STEALTH_DEST}/"

# Apply patches
echo "==> Applying patches..."
cd "${SRC_DIR}"
while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" =~ ^# ]] && continue
    PATCH_FILE="/patches/${patch_name}"
    [ ! -f "${PATCH_FILE}" ] && continue
    echo -n "  ${patch_name}... "
    if git apply --check "${PATCH_FILE}" 2>/dev/null; then
        git apply "${PATCH_FILE}" && echo "applied" || echo "failed"
    elif git apply --check --reverse "${PATCH_FILE}" 2>/dev/null; then
        echo "already applied"
    else
        echo "needs adaptation"
    fi
done < /patches/series

# Configure
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

# Build
echo "==> Building with ${NPROC} cores... (this takes 3-6 hours)"
echo "  Started at: $(date)"
autoninja -C "${BUILD_DIR}" -j "${NPROC}" chrome
echo "  Finished at: $(date)"

# Package
echo "==> Packaging..."
PKG_DIR=$(mktemp -d)
ABP_OUT="${PKG_DIR}/abp-chrome"
mkdir -p "${ABP_OUT}"
cd "${BUILD_DIR}"

for f in abp chrome chrome_crashpad_handler vk_swiftshader_icd.json icudtl.dat \
         v8_context_snapshot.bin snapshot_blob.bin; do
    [ -f "$f" ] && cp -a "$f" "${ABP_OUT}/"
done
cp -a *.so* "${ABP_OUT}/" 2>/dev/null || true
cp -a *.pak "${ABP_OUT}/" 2>/dev/null || true
cp -ra locales "${ABP_OUT}/" 2>/dev/null || true
cp -ra lib "${ABP_OUT}/" 2>/dev/null || true

# Rename chrome to abp if needed
[ -f "${ABP_OUT}/chrome" ] && [ ! -f "${ABP_OUT}/abp" ] && mv "${ABP_OUT}/chrome" "${ABP_OUT}/abp"
chmod +x "${ABP_OUT}/abp"

OUTPUT="/build/abp-stealth-linux-x64.tar.gz"
cd "${PKG_DIR}"
tar -czf "${OUTPUT}" abp-chrome/
rm -rf "${PKG_DIR}"
echo "  Package: ${OUTPUT} ($(du -h "${OUTPUT}" | cut -f1))"

# -------------------------------------------------------------------
# Upload to GitHub Release
# -------------------------------------------------------------------
if [ -n "${GH_TOKEN}" ] && [ -n "${GH_REPO}" ]; then
    echo "==> Uploading to GitHub Release..."
    export GH_TOKEN
    VERSION="stealth-$(date +%Y%m%d-%H%M%S)"

    gh release create "${VERSION}" \
        --repo "${GH_REPO}" \
        --title "ABP Stealth Build ${VERSION}" \
        --notes "Automated stealth build from Fly.io. ABP with C++ stealth patches." \
        "${OUTPUT}#abp-stealth-linux-x64.tar.gz"

    echo "  Uploaded as release: ${VERSION}"
    echo "  URL: https://github.com/${GH_REPO}/releases/tag/${VERSION}"
else
    echo "  No GH_TOKEN/GH_REPO set — skipping upload."
    echo "  Binary is at: ${OUTPUT}"
fi

echo ""
echo "============================================================"
echo "  BUILD COMPLETE at $(date)"
echo "============================================================"
ENTRYPOINT
chmod +x "${PROJECT_DIR}/scripts/fly-build-entrypoint.sh"

echo "  Deploying builder image to Fly..."
fly deploy \
    --app "${APP_NAME}" \
    --region "${REGION}" \
    --dockerfile /tmp/Dockerfile.fly-build \
    --build-only \
    --push \
    2>&1 | tail -5
echo ""

# -------------------------------------------------------------------
# Step 5: Run the build machine
# -------------------------------------------------------------------
echo "==> Step 5: Starting build machine"
echo "  This will take 3-6 hours for first build."
echo "  You can close this terminal — the machine runs independently."
echo "  Check status with: fly machine list -a ${APP_NAME}"
echo "  View logs with: fly logs -a ${APP_NAME}"
echo ""

fly machine run "registry.fly.io/${APP_NAME}:latest" \
    --app "${APP_NAME}" \
    --region "${REGION}" \
    --vm-size "${MACHINE_SIZE}" \
    --vm-memory "${MACHINE_RAM}" \
    --volume "${EXISTING_VOL}:/build" \
    --env "NPROC=16" \
    --env "GH_TOKEN=${GH_TOKEN}" \
    --env "GH_REPO=${GH_REPO}" \
    --restart "no" \
    2>&1

echo ""
echo "============================================================"
echo "  Build machine started!"
echo ""
echo "  Monitor progress:"
echo "    fly logs -a ${APP_NAME}"
echo ""
echo "  Check machine status:"
echo "    fly machine list -a ${APP_NAME}"
echo ""
echo "  When the build finishes, the machine stops automatically."
echo "  The binary will be uploaded as a GitHub Release."
echo ""
echo "  After the build, clean up:"
echo "    fly apps destroy ${APP_NAME} --yes"
echo "    # Or keep the app+volume for fast incremental rebuilds"
echo "============================================================"
