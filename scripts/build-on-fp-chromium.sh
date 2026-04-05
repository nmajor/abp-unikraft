#!/bin/bash
# Build ABP Stealth on fingerprint-chromium base.
#
# This replaces build-on-hetzner.sh with a fingerprint-chromium base instead
# of raw ABP Chromium. fingerprint-chromium provides ~20 stealth patches
# (canvas, WebGL, audio, fonts, Client Hints, CDP, UA, GPU, etc.) so we
# only need to add:
#   1. ABP protocol code (REST API, session management)
#   2. Stealth-extra patches (6 surfaces fp-chromium doesn't cover)
#   3. Feature edits (bandwidth metering, full page screenshot)
#
# Prerequisites:
#   - Fresh Ubuntu 22.04 server (Hetzner CCX33 recommended)
#   - ~50GB disk, 16+ cores, 64GB+ RAM
#   - GitHub CLI authenticated (gh auth login)
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/nmajor/abp-unikraft/main/scripts/build-on-fp-chromium.sh | bash
#
# Cost: CCX33 for ~4hrs = ~€1.20. CCX63 for ~2hrs = ~€0.92.
set -euo pipefail

REPO="nmajor/abp-unikraft"
BRANCH="main"
ABP_REPO_REF="${ABP_REPO_REF:-${BRANCH}}"
ABP_REPO_SHA="${ABP_REPO_SHA:-}"
BUILD_DIR="/root/build"
NPROC=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)

# fingerprint-chromium version to build against.
# Upstream's newest release can be binary-only for a while; this build needs
# a tag that still ships the source/build tooling in-repo.
# Keep this pinned to the latest source-available release we've validated here.
FP_CHROMIUM_TAG="${FP_CHROMIUM_TAG:-142.0.7444.175}"

# ABP source — the upstream Agent Browser Protocol repo.
ABP_REPO="https://github.com/theredsix/agent-browser-protocol.git"
ABP_BRANCH="${ABP_BRANCH:-dev}"

echo "============================================================"
echo "  ABP Stealth Build (fingerprint-chromium base)"
echo "  $(date)"
echo "  Cores: ${NPROC}  RAM: $(free -h | awk '/Mem:/{print $2}')"
echo "  Base: fingerprint-chromium ${FP_CHROMIUM_TAG}"
echo "============================================================"

# -------------------------------------------------------------------
# Step 1: System dependencies
# -------------------------------------------------------------------
echo ""
echo "==> [1/9] Installing system dependencies..."
apt-get update
apt-get install -y \
    build-essential clang cmake curl git gperf lld \
    libcups2-dev libdrm-dev libgbm-dev libgtk-3-dev libkrb5-dev \
    libnss3-dev libpango1.0-dev libpulse-dev libudev-dev libva-dev \
    libxcomposite-dev libxdamage-dev libxrandr-dev libxshmfence-dev \
    libegl-dev libevent-dev libflac-dev libgles-dev libharfbuzz-dev \
    libjpeg-dev libminizip-dev libopus-dev libpci-dev libpng-dev \
    libre2-dev libsnappy-dev libspeechd-dev libvulkan-dev libwayland-dev \
    libwebp-dev libx11-dev libx11-xcb-dev libxcb1-dev libxcursor-dev \
    libxext-dev libxfixes-dev libxi-dev libxinerama-dev libxkbcommon-dev \
    libxkbfile-dev libxtst-dev mesa-common-dev wayland-protocols \
    lsb-release ninja-build pkg-config python3 python3-pip \
    sudo wget xz-utils unzip file

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
echo "==> [2/9] GitHub authentication"
if [ -n "${GH_TOKEN:-}" ]; then
    echo "  Using GH_TOKEN from environment."
elif ! gh auth status &>/dev/null; then
    echo "  Please authenticate with GitHub to upload the release."
    echo "  Run: gh auth login"
    echo "  Or set GH_TOKEN env var with a personal access token."
    gh auth login
fi
echo "  Authenticated as: $(gh api user -q .login)"

# -------------------------------------------------------------------
# Step 3: Clone our patches repo
# -------------------------------------------------------------------
echo ""
echo "==> [3/9] Cloning ABP-unikraft patch repo..."
PATCH_REPO="/root/abp-unikraft"
if [ ! -d "${PATCH_REPO}" ]; then
    gh repo clone "${REPO}" "${PATCH_REPO}" -- --branch "${ABP_REPO_REF}"
else
    cd "${PATCH_REPO}"
    git fetch origin
fi
cd "${PATCH_REPO}"
if [ -n "${ABP_REPO_SHA}" ]; then
    git checkout --detach "${ABP_REPO_SHA}"
else
    git checkout "${ABP_REPO_REF}"
    git reset --hard "origin/${ABP_REPO_REF}"
fi
echo "  Using ABP-unikraft commit: $(git rev-parse HEAD)"
echo "  Patches at: ${PATCH_REPO}"

echo "  Running repo preflight gauntlet..."
chmod +x "${PATCH_REPO}/scripts/preflight-fp-chromium-build.sh"
bash "${PATCH_REPO}/scripts/preflight-fp-chromium-build.sh" repo "${PATCH_REPO}"

# -------------------------------------------------------------------
# Step 4: Clone fingerprint-chromium
# -------------------------------------------------------------------
echo ""
echo "==> [4/9] Fetching fingerprint-chromium source (tag: ${FP_CHROMIUM_TAG})..."

FP_DIR="/root/fingerprint-chromium"
if [ ! -d "${FP_DIR}" ]; then
    git clone --depth 1 --branch "${FP_CHROMIUM_TAG}" \
        https://github.com/adryfish/fingerprint-chromium.git "${FP_DIR}"
else
    echo "  Already exists, updating..."
    cd "${FP_DIR}" && git fetch && git checkout "${FP_CHROMIUM_TAG}"
fi
echo "  fingerprint-chromium at: ${FP_DIR}"

required_fp_files=(
    downloads.ini
    pruning.list
    domain_regex.list
    domain_substitution.list
    utils/downloads.py
    utils/patches.py
    utils/prune_binaries.py
    utils/domain_substitution.py
)

missing_fp_files=()
for path in "${required_fp_files[@]}"; do
    if [ ! -e "${FP_DIR}/${path}" ]; then
        missing_fp_files+=("${path}")
    fi
done

if [ "${#missing_fp_files[@]}" -ne 0 ]; then
    echo "ERROR: fingerprint-chromium tag ${FP_CHROMIUM_TAG} does not include the source build files this pipeline requires."
    printf 'Missing files:\n'
    printf '  - %s\n' "${missing_fp_files[@]}"
    echo "This upstream project sometimes publishes binary-only tags before releasing the full source tree."
    echo "Use the latest source-available tag instead."
    exit 1
fi

# -------------------------------------------------------------------
# Step 5: Download + patch Chromium source via fp-chromium build system
# -------------------------------------------------------------------
echo ""
echo "==> [5/9] Downloading and patching Chromium source..."
echo "  This downloads ~15GB of Chromium source. Takes 15-30 min."

mkdir -p "${BUILD_DIR}"
cd "${FP_DIR}"

if [ -d "${BUILD_DIR}/src" ]; then
    echo "  Cleaning previous Chromium source tree at ${BUILD_DIR}/src ..."
    rm -rf "${BUILD_DIR}/src"
fi

# Download Chromium source tarball
mkdir -p build/download_cache
python3 utils/downloads.py retrieve -c build/download_cache -i downloads.ini
python3 utils/downloads.py unpack -c build/download_cache -i downloads.ini -- "${BUILD_DIR}/src"

# Prune Google binaries
python3 utils/prune_binaries.py "${BUILD_DIR}/src" pruning.list

# Apply all patches (ungoogled-chromium + fingerprint-chromium)
python3 utils/patches.py apply "${BUILD_DIR}/src" patches

# Domain substitution
# fingerprint-chromium's domain substitution caches into a tarball and
# raises FileExistsError if the cache already exists. On watchdog reruns
# (same VM), that cache may be present from a previous attempt. Clean it
# proactively so the step is idempotent.
cache_path="build/domsubcache.tar.gz"
if [ -e "${cache_path}" ]; then
    echo "  Removing existing domain substitution cache: ${cache_path}"
    rm -f "${cache_path}"
fi
python3 utils/domain_substitution.py apply \
    -r domain_regex.list \
    -f domain_substitution.list \
    -c build/domsubcache.tar.gz \
    "${BUILD_DIR}/src"

SRC_DIR="${BUILD_DIR}/src"

# Ensure Rust toolchain (CIPD) is present for GN.
echo "  Ensuring Rust toolchain..."
chmod +x "${PATCH_REPO}/scripts/ensure-rust-toolchain.sh"
bash "${PATCH_REPO}/scripts/ensure-rust-toolchain.sh" "${SRC_DIR}"

# The source tarball does not include Chromium's prebuilt LLVM toolchain, and
# domain substitution can break the download URLs in Chromium helper scripts.
# Restore the real Google storage domains before invoking Chromium's updater.
echo "  Restoring toolchain download domains..."
sed -i 's|commondatastorage\.9oo91eapis\.qjz9zk|commondatastorage.googleapis.com|g' \
    "${SRC_DIR}/tools/clang/scripts/update.py" \
    "${SRC_DIR}/tools/clang/scripts/sync_deps.py" || true
sed -i 's|commondatastorage.9oo91eapis.qjz9zk|commondatastorage.googleapis.com|g' "${SRC_DIR}/tools/rust/update_rust.py" || true

echo "  Downloading Chromium Rust toolchain..."
python3 "${SRC_DIR}/tools/rust/update_rust.py"

echo "  Downloading Chromium Clang toolchain..."
python3 "${SRC_DIR}/tools/clang/scripts/update.py"


echo "  Chromium source patched with fingerprint-chromium stealth patches."

# Current fp-chromium releases can carry source/GN changes that need matching
# GN/export fixes before a component build will link successfully.
python3 - "${SRC_DIR}" <<'PY'
import pathlib
import sys

src_dir = pathlib.Path(sys.argv[1])
flags_state = src_dir / "components/webui/flags/flags_state.cc"
text = flags_state.read_text()

text = text.replace('#include "chrome/browser/unexpire_flags.h"\n', "")
text = text.replace(
    """    if (skip_feature_entry.Run(entry)) {
      if (flags::IsFlagExpired(flags_storage, entry.internal_name)) {
        desc.insert(0, "!!! NOTE: THIS FLAG IS EXPIRED AND MAY STOP FUNCTIONING OR BE REMOVED SOON !!! ");
      } else {
        continue;
      }
    }
""",
    """    if (skip_feature_entry.Run(entry)) {
      if (delegate_ && delegate_->ShouldExcludeFlag(flags_storage, entry)) {
        desc.insert(0, "!!! NOTE: THIS FLAG IS EXPIRED AND MAY STOP FUNCTIONING OR BE REMOVED SOON !!! ");
      } else {
        continue;
      }
    }
""",
)
text = text.replace(
    """    if (delegate_ && delegate_->ShouldExcludeFlag(storage, entry)) {
      if (!flags::IsFlagExpired(storage, entry.internal_name)) {
        continue;
      }
    }
""",
    """    if (delegate_ && delegate_->ShouldExcludeFlag(storage, entry)) {
      continue;
    }
""",
)

flags_state.write_text(text)
PY
python3 /root/abp-unikraft/scripts/patch_flags_state.py $SRC_DIR
perl -0pi -e 's|deps = \[\n    "//base",|deps = [\n    "//base",\n    "//components/ungoogled:ungoogled_switches",|s' \
    "${SRC_DIR}/third_party/blink/common/BUILD.gn"
perl -0pi -e 's|void UpdateUserAgentMetadataFingerprint\(UserAgentMetadata\* metadata\);|BLINK_COMMON_EXPORT void UpdateUserAgentMetadataFingerprint(UserAgentMetadata* metadata);|g; s|std::string GetUserAgentFingerprintBrandInfo\(\);|BLINK_COMMON_EXPORT std::string GetUserAgentFingerprintBrandInfo();|g' \
    "${SRC_DIR}/third_party/blink/public/common/user_agent/user_agent_metadata.h"
perl -0pi -e 's|deps = \[\n    ":generate_eventhandler_names",\n    ":make_deprecation_info",\n    "//base",|deps = [\n    ":generate_eventhandler_names",\n    ":make_deprecation_info",\n    "//base",\n    "//components/ungoogled:ungoogled_switches",|s' \
    "${SRC_DIR}/third_party/blink/renderer/core/BUILD.gn"
perl -0pi -e 's|deps = \[\n    "//device/vr/buildflags",|deps = [\n    "//device/vr/buildflags",\n    "//components/ungoogled:ungoogled_switches",|s' \
    "${SRC_DIR}/third_party/blink/renderer/modules/webgl/BUILD.gn"
perl -0pi -e 's|deps = \[\n    ":embedder_support",|deps = [\n    ":embedder_support",\n    "//components/ungoogled:ungoogled_switches",|s' \
    "${SRC_DIR}/components/embedder_support/BUILD.gn"

# -------------------------------------------------------------------
# Step 6: Install Chromium build dependencies
# -------------------------------------------------------------------
echo ""
echo "==> [6/9] Installing Chromium build dependencies..."
cd "${SRC_DIR}"
if [ -f "build/install-build-deps.sh" ]; then
    sudo bash build/install-build-deps.sh --no-prompt --no-chromeos-fonts --no-arm --no-nacl || true
fi

# Ensure Node.js and esbuild expected by Chromium/DevTools are present in this
# tarball-based checkout (no gclient runhooks in this flow).
echo "  Ensuring Node.js and esbuild toolchain..."
chmod +x "${PATCH_REPO}/scripts/ensure-node-esbuild.sh"
bash "${PATCH_REPO}/scripts/ensure-node-esbuild.sh" "${SRC_DIR}"

# -------------------------------------------------------------------
# Step 7: Overlay ABP protocol code
# -------------------------------------------------------------------
echo ""
echo "==> [7/9] Overlaying ABP protocol + stealth-extra patches..."

# 7a: Fetch ABP source to extract the protocol code.
# We only need chrome/browser/abp/ and its BUILD.gn integration.
ABP_EXTRACT="/root/abp-source"
if [ ! -d "${ABP_EXTRACT}" ]; then
    echo "  Cloning ABP source (sparse, protocol code only)..."
    git clone --depth 1 --branch "${ABP_BRANCH}" --no-checkout "${ABP_REPO}" "${ABP_EXTRACT}"
    cd "${ABP_EXTRACT}"
    git sparse-checkout init --cone
    git sparse-checkout set chrome/browser/abp
    git checkout
else
    echo "  ABP source already extracted."
fi

# 7b: Copy ABP protocol code into the fingerprint-chromium tree.
echo "  Copying ABP protocol code..."
if [ -d "${ABP_EXTRACT}/chrome/browser/abp" ]; then
    cp -r "${ABP_EXTRACT}/chrome/browser/abp" "${SRC_DIR}/chrome/browser/"
    echo "  OK — ABP protocol code copied to ${SRC_DIR}/chrome/browser/abp/"
else
    echo "  ERROR: ABP protocol code not found at ${ABP_EXTRACT}/chrome/browser/abp"
    echo "  Falling back to full clone..."
    cd "${ABP_EXTRACT}" && git sparse-checkout disable && git checkout
    cp -r "${ABP_EXTRACT}/chrome/browser/abp" "${SRC_DIR}/chrome/browser/"
fi

# 7b.1: Verify the overlaid ABP source does not reintroduce legacy stealth
# switch namespaces or conflicting launch flags.
echo "  Verifying ABP overlay contract..."
chmod +x "${PATCH_REPO}/scripts/verify-abp-overlay-contract.sh"
bash "${PATCH_REPO}/scripts/verify-abp-overlay-contract.sh" "${SRC_DIR}"

# 7c: Apply stealth-extra edits (surfaces fingerprint-chromium doesn't cover).
echo "  Applying stealth-extra edits..."
chmod +x "${PATCH_REPO}/scripts/apply-stealth-extra-edits.sh"
bash "${PATCH_REPO}/scripts/apply-stealth-extra-edits.sh" "${SRC_DIR}"

# 7d: Apply feature edits (bandwidth metering + full page screenshot).
echo "  Applying feature edits..."
chmod +x "${PATCH_REPO}/scripts/apply-feature-edits.sh"
bash "${PATCH_REPO}/scripts/apply-feature-edits.sh" "${SRC_DIR}"

# Re-run contract verification after our edits.
echo "  Re-verifying ABP overlay contract..."
bash "${PATCH_REPO}/scripts/verify-abp-overlay-contract.sh" "${SRC_DIR}"

# -------------------------------------------------------------------
# Step 8: Configure + Build
# -------------------------------------------------------------------
echo ""
echo "==> [8/9] Configuring and building..."
echo "  Build started at: $(date)"

RELEASE_DIR="${SRC_DIR}/out/Release"
mkdir -p "${RELEASE_DIR}"

# Use fingerprint-chromium's flags.gn as base, with our overrides.
if [ -f "${FP_DIR}/flags.gn" ]; then
    cp "${FP_DIR}/flags.gn" "${RELEASE_DIR}/args.gn"
else
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
fi

# We are building on Ubuntu directly, not against Chromium's Debian sysroot.
# Keep GN aligned with the documented Hetzner workflow so GN/ninja do not look
# for sysroot-only helpers like cups-config under build/linux/*-sysroot.
cat >> "${RELEASE_DIR}/args.gn" <<'GNARGS'
use_sysroot = false
use_cups = false
# Workaround: Ubuntu 22.04's libva-dev (<2.19) lacks AV1 refresh_frame_flags
# and causes compile errors under VAAPI. Disable VAAPI for this build.
use_vaapi = false
GNARGS

# GN: prefer prebuilt binary over local bootstrap (more reliable on Ubuntu 22.04).
# This avoids libstdc++ C++20 ranges issues when building GN with clang+libstdc++11.
if [ ! -x "${SRC_DIR}/out/Release/gn" ]; then
    echo "  Fetching prebuilt GN binary..."
    cd "${SRC_DIR}"
    mkdir -p out/Release
    if command -v wget >/dev/null 2>&1; then
        wget -q -O /tmp/gn.zip "https://chrome-infra-packages.appspot.com/dl/gn/gn/linux-amd64/+/latest" || true
    else
        curl -fsSL -o /tmp/gn.zip "https://chrome-infra-packages.appspot.com/dl/gn/gn/linux-amd64/+/latest" || true
    fi
    if [ -s /tmp/gn.zip ]; then
        ( cd out/Release && unzip -oq /tmp/gn.zip && chmod +x gn )
        rm -f /tmp/gn.zip
    fi
fi

# Fallback: attempt local bootstrap only if the prebuilt GN isn't available.
if [ ! -x "${SRC_DIR}/out/Release/gn" ]; then
    echo "  Prebuilt GN unavailable; attempting local bootstrap..."
    cd "${SRC_DIR}"
    python3 tools/gn/bootstrap/bootstrap.py --skip-generate-buildfiles -j "${NPROC}" -o out/Release/gn
fi

echo "  Running source preflight gauntlet..."
bash "${PATCH_REPO}/scripts/preflight-fp-chromium-build.sh" src "${SRC_DIR}" "${PATCH_REPO}"

echo "  Building with ${NPROC} cores..."
ninja -C "${RELEASE_DIR}" -j "${NPROC}" chrome chromedriver

echo "  Build finished at: $(date)"

# -------------------------------------------------------------------
# Step 9: Package + Upload
# -------------------------------------------------------------------
echo ""
echo "==> [9/9] Packaging and uploading..."

PKG_DIR=$(mktemp -d)
ABP_OUT="${PKG_DIR}/abp-chrome"
mkdir -p "${ABP_OUT}"
cd "${RELEASE_DIR}"

# Copy binary and required files.
for f in chrome chromedriver chrome_crashpad_handler vk_swiftshader_icd.json \
         icudtl.dat v8_context_snapshot.bin snapshot_blob.bin; do
    [ -f "$f" ] && cp -a "$f" "${ABP_OUT}/"
done
cp -a *.so* "${ABP_OUT}/" 2>/dev/null || true
cp -a *.pak "${ABP_OUT}/" 2>/dev/null || true
cp -ra locales "${ABP_OUT}/" 2>/dev/null || true
cp -ra lib "${ABP_OUT}/" 2>/dev/null || true

# Rename chrome → abp for ABP compatibility.
[ -f "${ABP_OUT}/chrome" ] && [ ! -f "${ABP_OUT}/abp" ] && mv "${ABP_OUT}/chrome" "${ABP_OUT}/abp"
[ -f "${ABP_OUT}/abp" ] && chmod +x "${ABP_OUT}/abp"

if [ -x "${ABP_OUT}/abp" ]; then
    echo "  Browser version: $("${ABP_OUT}/abp" --version 2>/dev/null || echo 'unavailable')"
fi
if [ -x "${ABP_OUT}/chromedriver" ]; then
    echo "  Chromedriver version: $("${ABP_OUT}/chromedriver" --version 2>/dev/null || echo 'unavailable')"
fi

OUTPUT="/root/abp-stealth-linux-x64.tar.gz"
cd "${PKG_DIR}"
tar -czf "${OUTPUT}" abp-chrome/
rm -rf "${PKG_DIR}"

echo "  Package: ${OUTPUT}"
echo "  Size: $(du -h "${OUTPUT}" | cut -f1)"

# Upload to GitHub Release.
VERSION="stealth-fp-$(date +%Y%m%d-%H%M%S)"

gh release create "${VERSION}" \
    --repo "${REPO}" \
    --title "ABP Stealth Build ${VERSION} (fp-chromium ${FP_CHROMIUM_TAG})" \
    --notes "ABP Chromium built on fingerprint-chromium ${FP_CHROMIUM_TAG}.
Base: fingerprint-chromium (ungoogled-chromium + stealth patches)
Extra: ABP protocol + stealth-extra patches + feature edits
Stealth patches from upstream: canvas, WebGL, audio, fonts, Client Hints, CDP, UA, GPU
Stealth-extra patches (ours): pointer/hover, screen, window dimensions, deviceMemory, automation flags
Runtime contract: native fingerprint-chromium switches only; no legacy abp-fingerprint remapping" \
    "${OUTPUT}#abp-stealth-linux-x64.tar.gz"

RELEASE_URL="https://github.com/${REPO}/releases/tag/${VERSION}"

echo ""
echo "============================================================"
echo "  ALL DONE!"
echo "  $(date)"
echo "============================================================"
echo ""
echo "  Release: ${RELEASE_URL}"
echo "  Base: fingerprint-chromium ${FP_CHROMIUM_TAG}"
echo "  Binary: abp-stealth-linux-x64.tar.gz"
echo ""
echo "  Next steps:"
echo "    1. Update Dockerfile ABP_STEALTH_VERSION to: ${VERSION}"
echo "    2. Push to trigger KraftCloud image rebuild"
echo "    3. DELETE THIS SERVER to stop billing"
echo "============================================================"

if [ "${SKIP_POWEROFF:-}" != "1" ]; then
    echo "  Auto-powering off in 60 seconds..."
    sleep 60
    poweroff
fi
