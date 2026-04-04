#!/bin/bash
# Verify that the overlaid ABP source uses the modern fingerprint-chromium
# contract and does not reintroduce legacy ABP stealth remapping or stale
# launch-time overrides.
#
# Usage: ./verify-abp-overlay-contract.sh /path/to/chromium-src
set -euo pipefail

SRC="${1:?Usage: $0 /path/to/chromium-src}"
ABP_DIR="${SRC}/chrome/browser/abp"

if [ ! -d "${ABP_DIR}" ]; then
    echo "ERROR: ABP source not found at ${ABP_DIR}"
    exit 1
fi

fail=0

check_absent() {
    local pattern="$1"
    local label="$2"
    local tmp
    tmp="$(mktemp)"
    if grep -RInE \
        --exclude-dir=test \
        --exclude-dir=test_pages \
        --exclude='*.md' \
        "${pattern}" "${ABP_DIR}" >"${tmp}" 2>/dev/null; then
        echo "ERROR: Found forbidden ${label} in ABP overlay:"
        cat "${tmp}"
        fail=1
    else
        echo "  OK   no ${label}"
    fi
    rm -f "${tmp}"
}

echo "==> Verifying ABP overlay contract..."

if [ -d "${ABP_DIR}/stealth" ]; then
    echo "ERROR: Found legacy ABP stealth directory in overlay:"
    echo "  ${ABP_DIR}/stealth"
    fail=1
else
    echo "  OK   no legacy chrome/browser/abp/stealth directory"
fi

check_absent 'abp-fingerprint(-platform|-hardware-concurrency|-gpu-vendor|-gpu-renderer)?' 'legacy abp-fingerprint switches'
check_absent 'abp-timezone' 'legacy abp-timezone switch'
check_absent 'UserAgentClientHint' 'Client Hints disablement'
check_absent 'ozone-override-screen-size' 'forced ozone screen override'
check_absent 'Chrome/129\.0\.0\.0' 'hardcoded legacy Chrome 129 UA'

if [ "${fail}" -ne 0 ]; then
    echo ""
    echo "ABP overlay contract verification failed."
    echo "The overlaid ABP source must use native fingerprint-chromium switches"
    echo "and must not inject legacy stealth overrides."
    exit 1
fi

echo "==> ABP overlay contract is clean."
