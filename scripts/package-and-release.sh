#!/bin/bash
# Package the built ABP binary and upload as a GitHub Release.
#
# Run this on the build server after a successful build:
#   ./scripts/package-and-release.sh
#
# Prerequisites:
#   - Successful build at /root/build/src/out/Release
#   - gh CLI authenticated (gh auth login)
set -euo pipefail

REPO="nmajor/abp-unikraft"
RELEASE_DIR="/root/build/src/out/Release"

if [ ! -f "${RELEASE_DIR}/abp" ] && [ ! -f "${RELEASE_DIR}/chrome" ]; then
    echo "ERROR: No binary found at ${RELEASE_DIR}/abp or ${RELEASE_DIR}/chrome"
    echo "       Did the build complete successfully?"
    exit 1
fi

# -------------------------------------------------------------------
# Step 1: Package
# -------------------------------------------------------------------
echo "==> Packaging..."

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
# Step 2: Upload to GitHub Release
# -------------------------------------------------------------------
echo ""
echo "==> Uploading to GitHub Release..."

if ! gh auth status &>/dev/null; then
    echo "  Not authenticated. Run: gh auth login"
    exit 1
fi

VERSION="stealth-$(date +%Y%m%d-%H%M%S)"

gh release create "${VERSION}" \
    --repo "${REPO}" \
    --title "ABP Stealth + Features ${VERSION}" \
    --notes "ABP Chromium with C++ stealth patches, bandwidth metering, and full page screenshot endpoint." \
    "${OUTPUT}#abp-stealth-linux-x64.tar.gz"

RELEASE_URL="https://github.com/${REPO}/releases/tag/${VERSION}"

echo ""
echo "============================================================"
echo "  RELEASE PUBLISHED"
echo "============================================================"
echo ""
echo "  Release: ${RELEASE_URL}"
echo "  Binary:  abp-stealth-linux-x64.tar.gz"
echo ""
echo "  Next steps:"
echo "    1. Update Dockerfile to download from this release"
echo "    2. Push to trigger KraftCloud image rebuild"
echo "    3. DELETE THIS SERVER to stop billing"
echo "============================================================"
