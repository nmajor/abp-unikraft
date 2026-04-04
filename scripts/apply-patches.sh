#!/bin/bash
# Apply ABP stealth patches to the Chromium/ABP source tree.
#
# Usage: ./scripts/apply-patches.sh /path/to/abp-chromium-src
#
# This script:
# 1. Copies new stealth source files into the ABP source tree
# 2. Applies each patch in order from the series file
# 3. Reports success/failure for each patch
set -euo pipefail

if [ "${ALLOW_LEGACY_ABP_STEALTH:-0}" != "1" ]; then
    echo "ERROR: scripts/apply-patches.sh applies the retired legacy ABP stealth patch stack."
    echo "Use scripts/apply-stealth-extra-edits.sh with the fp-chromium build path instead."
    echo "Set ALLOW_LEGACY_ABP_STEALTH=1 only for forensic/reference work."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="${PROJECT_DIR}/patches"
SRC_DIR="${PROJECT_DIR}/src"

if [ $# -lt 1 ]; then
    echo "Usage: $0 /path/to/abp-chromium-src"
    echo ""
    echo "The path should be the root of the ABP Chromium source tree"
    echo "(the directory containing chrome/, content/, third_party/, etc.)"
    exit 1
fi

CHROMIUM_SRC="$1"

if [ ! -d "${CHROMIUM_SRC}/chrome/browser/abp" ]; then
    echo "ERROR: ${CHROMIUM_SRC}/chrome/browser/abp not found."
    echo "This does not appear to be an ABP Chromium source tree."
    exit 1
fi

echo "==> Step 1: Copy new stealth source files"
STEALTH_DEST="${CHROMIUM_SRC}/chrome/browser/abp/stealth"
mkdir -p "${STEALTH_DEST}"
cp -v "${SRC_DIR}/chrome/browser/abp/stealth/"* "${STEALTH_DEST}/"
echo "    Copied stealth files to ${STEALTH_DEST}"

echo ""
echo "==> Step 2: Apply patches from series file"
SERIES_FILE="${PATCHES_DIR}/series"

if [ ! -f "${SERIES_FILE}" ]; then
    echo "ERROR: Series file not found: ${SERIES_FILE}"
    exit 1
fi

TOTAL=0
SUCCESS=0
FAILED=0

while IFS= read -r patch_name; do
    # Skip empty lines and comments.
    [[ -z "$patch_name" || "$patch_name" =~ ^# ]] && continue

    PATCH_FILE="${PATCHES_DIR}/${patch_name}"
    TOTAL=$((TOTAL + 1))

    if [ ! -f "${PATCH_FILE}" ]; then
        echo "  SKIP: ${patch_name} (file not found)"
        FAILED=$((FAILED + 1))
        continue
    fi

    echo -n "  Applying ${patch_name}... "

    # Try to apply with git apply first, fall back to patch command.
    if cd "${CHROMIUM_SRC}" && git apply --check "${PATCH_FILE}" 2>/dev/null; then
        git apply "${PATCH_FILE}"
        echo "OK"
        SUCCESS=$((SUCCESS + 1))
    elif cd "${CHROMIUM_SRC}" && git apply --check --3way "${PATCH_FILE}" 2>/dev/null; then
        git apply --3way "${PATCH_FILE}"
        echo "OK (3-way)"
        SUCCESS=$((SUCCESS + 1))
    else
        # Patches are template-style (context may not match exactly).
        # Log the failure but continue — manual adaptation may be needed.
        echo "NEEDS MANUAL ADAPTATION"
        echo "    The exact context lines may differ in your Chromium version."
        echo "    Review the patch and apply the changes manually."
        FAILED=$((FAILED + 1))
    fi
done < "${SERIES_FILE}"

echo ""
echo "==> Results: ${SUCCESS}/${TOTAL} patches applied, ${FAILED} need manual work"
echo ""

if [ ${FAILED} -gt 0 ]; then
    echo "NOTE: Some patches may need manual adaptation for your Chromium version."
    echo "The patches are written as templates showing WHAT to change and WHERE."
    echo "The exact line numbers and surrounding context may differ."
    echo ""
    echo "Each patch file has a Description header explaining the intent."
    echo "Use that to guide manual application."
fi
