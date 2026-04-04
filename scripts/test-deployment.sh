#!/bin/bash
# Comprehensive test suite for ABP Stealth deployment.
# Tests regression (existing features) + new features (bandwidth, full page screenshot).
#
# Usage: ./scripts/test-deployment.sh <instance-url>
# Example: ./scripts/test-deployment.sh https://abp-unikraft.fra.unikraft.app
set -uo pipefail

BASE_URL="${1:?Usage: $0 <instance-url>}"
BASE_URL="${BASE_URL%/}"  # strip trailing slash
EXPECTED_PLATFORM="${EXPECTED_PLATFORM:-Win32}"
EXPECTED_UADATA_PLATFORM="${EXPECTED_UADATA_PLATFORM:-Windows}"
EXPECTED_MIN_HARDWARE_CONCURRENCY="${EXPECTED_MIN_HARDWARE_CONCURRENCY:-4}"
EXPECTED_MIN_SCREEN_WIDTH="${EXPECTED_MIN_SCREEN_WIDTH:-1280}"
EXPECTED_MIN_SCREEN_HEIGHT="${EXPECTED_MIN_SCREEN_HEIGHT:-720}"
EXPECTED_CHROME_MAJOR="${EXPECTED_CHROME_MAJOR:-}"

PASS=0
FAIL=0
TOTAL=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

test_result() {
    local name="$1"
    local passed="$2"
    local detail="${3:-}"
    TOTAL=$((TOTAL + 1))
    if [ "$passed" = "true" ]; then
        PASS=$((PASS + 1))
        echo -e "  ${GREEN}PASS${NC}  ${name}${detail:+ — $detail}"
    else
        FAIL=$((FAIL + 1))
        echo -e "  ${RED}FAIL${NC}  ${name}${detail:+ — $detail}"
    fi
}

api() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local timeout="${4:-30}"

    if [ -n "$body" ]; then
        curl -sS --max-time "$timeout" -X "$method" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "${BASE_URL}${path}" 2>&1
    else
        curl -sS --max-time "$timeout" -X "$method" \
            "${BASE_URL}${path}" 2>&1
    fi
}

echo "============================================================"
echo "  ABP Stealth Deployment Tests"
echo "  Target: ${BASE_URL}"
echo "  $(date)"
echo "============================================================"
echo ""

# -------------------------------------------------------------------
# 1. Browser Status (wake from zero)
# -------------------------------------------------------------------
echo "==> 1. Browser Status"
RESP=$(api GET /api/v1/browser/status)
READY=$(echo "$RESP" | jq -r '.ready // empty' 2>/dev/null)
test_result "GET /browser/status returns ready" "$([ "$READY" = "true" ] && echo true || echo false)" "$READY"

# -------------------------------------------------------------------
# 2. Tab Management
# -------------------------------------------------------------------
echo ""
echo "==> 2. Tab Management"
TABS=$(api GET /api/v1/tabs)
TAB_COUNT=$(echo "$TABS" | jq 'length' 2>/dev/null)
test_result "GET /tabs returns array" "$([ "$TAB_COUNT" -ge 1 ] 2>/dev/null && echo true || echo false)" "count=$TAB_COUNT"

TAB_ID=$(echo "$TABS" | jq -r '.[0].id // empty' 2>/dev/null)
test_result "First tab has an ID" "$([ -n "$TAB_ID" ] && echo true || echo false)" "$TAB_ID"

if [ -z "$TAB_ID" ]; then
    echo "  FATAL: No tab ID, cannot continue"
    exit 1
fi

# -------------------------------------------------------------------
# 3. Navigation
# -------------------------------------------------------------------
echo ""
echo "==> 3. Navigation"
NAV=$(api POST "/api/v1/tabs/${TAB_ID}/navigate" '{"url":"https://example.com"}' 60)
NAV_TITLE=$(echo "$NAV" | jq -r '.result.title // empty' 2>/dev/null)
test_result "Navigate to example.com" "$([ -n "$NAV_TITLE" ] && echo true || echo false)" "title=$NAV_TITLE"

HAS_SS_AFTER=$(echo "$NAV" | jq -r '.screenshot_after.data // empty' 2>/dev/null)
test_result "Response has screenshot_after" "$([ -n "$HAS_SS_AFTER" ] && echo true || echo false)" "data length=${#HAS_SS_AFTER}"

HAS_PROFILING=$(echo "$NAV" | jq -r '.profiling.total_ms // empty' 2>/dev/null)
test_result "Response has profiling.total_ms" "$([ -n "$HAS_PROFILING" ] && echo true || echo false)" "${HAS_PROFILING}ms"

# -------------------------------------------------------------------
# 4. Bandwidth Metering (NEW)
# -------------------------------------------------------------------
echo ""
echo "==> 4. Bandwidth Metering (NEW FEATURE)"
NET_BYTES_RECV=$(echo "$NAV" | jq -r '.network.bytes_received // empty' 2>/dev/null)
NET_BYTES_SENT=$(echo "$NAV" | jq -r '.network.bytes_sent // empty' 2>/dev/null)
NET_BYTES_TOTAL=$(echo "$NAV" | jq -r '.network.bytes_total // empty' 2>/dev/null)
NET_SESSION_RECV=$(echo "$NAV" | jq -r '.network.session_bytes_received // empty' 2>/dev/null)
NET_SESSION_SENT=$(echo "$NAV" | jq -r '.network.session_bytes_sent // empty' 2>/dev/null)

test_result "network.bytes_received present" "$([ -n "$NET_BYTES_RECV" ] && echo true || echo false)" "$NET_BYTES_RECV"
test_result "network.bytes_sent present" "$([ -n "$NET_BYTES_SENT" ] && echo true || echo false)" "$NET_BYTES_SENT"
test_result "network.bytes_total present" "$([ -n "$NET_BYTES_TOTAL" ] && echo true || echo false)" "$NET_BYTES_TOTAL"
test_result "network.session_bytes_received present" "$([ -n "$NET_SESSION_RECV" ] && echo true || echo false)" "$NET_SESSION_RECV"
test_result "network.session_bytes_sent present" "$([ -n "$NET_SESSION_SENT" ] && echo true || echo false)" "$NET_SESSION_SENT"
test_result "bytes_received > 0 for navigation" "$(echo "$NET_BYTES_RECV" | awk '{print ($1 > 0) ? "true" : "false"}' 2>/dev/null)" "$NET_BYTES_RECV bytes"

# -------------------------------------------------------------------
# 5. Text Extraction
# -------------------------------------------------------------------
echo ""
echo "==> 5. Text Extraction"
TEXT=$(api POST "/api/v1/tabs/${TAB_ID}/text" '{}')
TEXT_CONTENT=$(echo "$TEXT" | jq -r '.text // empty' 2>/dev/null)
HAS_EXAMPLE=$(echo "$TEXT_CONTENT" | grep -ci "example" || true)
test_result "Text extraction returns content" "$([ -n "$TEXT_CONTENT" ] && echo true || echo false)" "${#TEXT_CONTENT} chars"
test_result "Text contains 'example'" "$([ "$HAS_EXAMPLE" -gt 0 ] && echo true || echo false)"

# -------------------------------------------------------------------
# 6. JavaScript Execution
# -------------------------------------------------------------------
echo ""
echo "==> 6. JavaScript Execution"
EXEC=$(api POST "/api/v1/tabs/${TAB_ID}/execute" '{"script":"document.title"}')
EXEC_VAL=$(echo "$EXEC" | jq -r '.result.value // empty' 2>/dev/null)
test_result "Execute JS returns document.title" "$([ -n "$EXEC_VAL" ] && echo true || echo false)" "$EXEC_VAL"

# -------------------------------------------------------------------
# 7. Viewport Screenshot
# -------------------------------------------------------------------
echo ""
echo "==> 7. Viewport Screenshot"
SS=$(api POST "/api/v1/tabs/${TAB_ID}/screenshot" '{}')
SS_WIDTH=$(echo "$SS" | jq -r '.screenshot_after.width // empty' 2>/dev/null)
SS_HEIGHT=$(echo "$SS" | jq -r '.screenshot_after.height // empty' 2>/dev/null)
SS_FORMAT=$(echo "$SS" | jq -r '.screenshot_after.format // empty' 2>/dev/null)
SS_DATA=$(echo "$SS" | jq -r '.screenshot_after.data // empty' 2>/dev/null)
test_result "Screenshot has dimensions" "$([ -n "$SS_WIDTH" ] && [ -n "$SS_HEIGHT" ] && echo true || echo false)" "${SS_WIDTH}x${SS_HEIGHT}"
test_result "Screenshot format is webp" "$([ "$SS_FORMAT" = "webp" ] && echo true || echo false)" "$SS_FORMAT"
test_result "Screenshot has base64 data" "$([ ${#SS_DATA} -gt 100 ] && echo true || echo false)" "${#SS_DATA} chars"

# -------------------------------------------------------------------
# 8. Full Page Screenshot (NEW)
# -------------------------------------------------------------------
echo ""
echo "==> 8. Full Page Screenshot (NEW FEATURE)"

# Navigate to a taller page first
api POST "/api/v1/tabs/${TAB_ID}/navigate" '{"url":"https://en.wikipedia.org/wiki/Earth"}' 60 > /dev/null 2>&1

FULL_SS=$(api POST "/api/v1/tabs/${TAB_ID}/screenshot/full" '{"quality": 60}' 60)
FULL_SS_WIDTH=$(echo "$FULL_SS" | jq -r '.screenshot.width // empty' 2>/dev/null)
FULL_SS_HEIGHT=$(echo "$FULL_SS" | jq -r '.screenshot.height // empty' 2>/dev/null)
FULL_SS_FULL=$(echo "$FULL_SS" | jq -r '.screenshot.full_page // empty' 2>/dev/null)
FULL_SS_DATA=$(echo "$FULL_SS" | jq -r '.screenshot.data // empty' 2>/dev/null)
FULL_SS_ERR=$(echo "$FULL_SS" | jq -r '.error // empty' 2>/dev/null)

test_result "Full page screenshot endpoint responds" "$([ -n "$FULL_SS_WIDTH" ] || [ -n "$FULL_SS_ERR" ] && echo true || echo false)" "w=$FULL_SS_WIDTH h=$FULL_SS_HEIGHT err=$FULL_SS_ERR"
test_result "full_page flag is true" "$([ "$FULL_SS_FULL" = "true" ] && echo true || echo false)" "$FULL_SS_FULL"
test_result "Full page height > viewport" "$([ "${FULL_SS_HEIGHT:-0}" -gt "${SS_HEIGHT:-800}" ] 2>/dev/null && echo true || echo false)" "full=${FULL_SS_HEIGHT} vs viewport=${SS_HEIGHT}"
test_result "Full page has base64 data" "$([ ${#FULL_SS_DATA} -gt 100 ] 2>/dev/null && echo true || echo false)" "${#FULL_SS_DATA} chars"

# -------------------------------------------------------------------
# 9. Stealth Checks
# -------------------------------------------------------------------
echo ""
echo "==> 9. Stealth Verification"

# One-shot fingerprint contract probe.
FP=$(api POST "/api/v1/tabs/${TAB_ID}/execute" '{"script":"JSON.stringify({ua:navigator.userAgent,platform:navigator.platform,uaDataPlatform:(navigator.userAgentData&&navigator.userAgentData.platform)||\"\",webdriver:navigator.webdriver,plugins:navigator.plugins.length,deviceMemory:(typeof navigator.deviceMemory===\"number\")?navigator.deviceMemory:null,hardwareConcurrency:navigator.hardwareConcurrency,screenWidth:screen.width,screenHeight:screen.height,availWidth:screen.availWidth,availHeight:screen.availHeight,outerWidth:window.outerWidth,outerHeight:window.outerHeight,pointerFine:matchMedia(\"(pointer: fine)\").matches,hoverHover:matchMedia(\"(hover: hover)\").matches,windowChrome:typeof window.chrome})"}')
FP_JSON=$(echo "$FP" | jq -r '.result.value // empty' 2>/dev/null)

UA_VAL=$(echo "$FP_JSON" | jq -r '.ua // empty' 2>/dev/null)
PL_VAL=$(echo "$FP_JSON" | jq -r '.plugins // empty' 2>/dev/null)
WD_VAL=$(echo "$FP_JSON" | jq -r '.webdriver // empty' 2>/dev/null)
PLATFORM_VAL=$(echo "$FP_JSON" | jq -r '.platform // empty' 2>/dev/null)
UADATA_PLATFORM_VAL=$(echo "$FP_JSON" | jq -r '.uaDataPlatform // empty' 2>/dev/null)
DEVMEM_VAL=$(echo "$FP_JSON" | jq -r '.deviceMemory // empty' 2>/dev/null)
HWC_VAL=$(echo "$FP_JSON" | jq -r '.hardwareConcurrency // empty' 2>/dev/null)
SCREEN_W_VAL=$(echo "$FP_JSON" | jq -r '.screenWidth // empty' 2>/dev/null)
SCREEN_H_VAL=$(echo "$FP_JSON" | jq -r '.screenHeight // empty' 2>/dev/null)
POINTER_VAL=$(echo "$FP_JSON" | jq -r '.pointerFine // empty' 2>/dev/null)
HOVER_VAL=$(echo "$FP_JSON" | jq -r '.hoverHover // empty' 2>/dev/null)
WC_VAL=$(echo "$FP_JSON" | jq -r '.windowChrome // empty' 2>/dev/null)
UA_MAJOR=$(echo "$UA_VAL" | sed -n 's/.*Chrome\/\([0-9][0-9]*\).*/\1/p' | head -n1)
HAS_HEADLESS=$(echo "$UA_VAL" | grep -ci "headless" || true)

test_result "navigator.webdriver is false" "$([ "$WD_VAL" = "false" ] && echo true || echo false)" "$WD_VAL"
test_result "navigator.plugins.length > 0" "$([ "${PL_VAL:-0}" -gt 0 ] 2>/dev/null && echo true || echo false)" "$PL_VAL"
test_result "User-Agent has no 'Headless'" "$([ "$HAS_HEADLESS" = "0" ] && echo true || echo false)" "$(echo "$UA_VAL" | head -c 80)"
test_result "window.chrome is object" "$([ "$WC_VAL" = "object" ] && echo true || echo false)" "$WC_VAL"
test_result "navigator.platform matches expected" "$([ "$PLATFORM_VAL" = "$EXPECTED_PLATFORM" ] && echo true || echo false)" "$PLATFORM_VAL"
test_result "navigator.userAgentData.platform matches expected" "$([ -n "$UADATA_PLATFORM_VAL" ] && [ "$UADATA_PLATFORM_VAL" = "$EXPECTED_UADATA_PLATFORM" ] && echo true || echo false)" "$UADATA_PLATFORM_VAL"
test_result "deviceMemory is reported" "$([ -n "$DEVMEM_VAL" ] && [ "$DEVMEM_VAL" != "null" ] && echo true || echo false)" "$DEVMEM_VAL"
test_result "hardwareConcurrency is realistic" "$([ "${HWC_VAL:-0}" -ge "${EXPECTED_MIN_HARDWARE_CONCURRENCY}" ] 2>/dev/null && echo true || echo false)" "$HWC_VAL"
test_result "screen.width is realistic" "$([ "${SCREEN_W_VAL:-0}" -ge "${EXPECTED_MIN_SCREEN_WIDTH}" ] 2>/dev/null && echo true || echo false)" "$SCREEN_W_VAL"
test_result "screen.height is realistic" "$([ "${SCREEN_H_VAL:-0}" -ge "${EXPECTED_MIN_SCREEN_HEIGHT}" ] 2>/dev/null && echo true || echo false)" "$SCREEN_H_VAL"
test_result "(pointer: fine) is true" "$([ "$POINTER_VAL" = "true" ] && echo true || echo false)" "$POINTER_VAL"
test_result "(hover: hover) is true" "$([ "$HOVER_VAL" = "true" ] && echo true || echo false)" "$HOVER_VAL"
if [ -n "$EXPECTED_CHROME_MAJOR" ]; then
    test_result "Chrome major matches expected" "$([ "$UA_MAJOR" = "$EXPECTED_CHROME_MAJOR" ] && echo true || echo false)" "$UA_MAJOR"
fi

# -------------------------------------------------------------------
# 10. Interaction (click, type, keyboard)
# -------------------------------------------------------------------
echo ""
echo "==> 10. Interaction"

# Navigate to a search page
api POST "/api/v1/tabs/${TAB_ID}/navigate" '{"url":"https://example.com"}' 60 > /dev/null 2>&1

CLICK=$(api POST "/api/v1/tabs/${TAB_ID}/click" '{"x":300,"y":200}')
CLICK_OK=$(echo "$CLICK" | jq -r '.screenshot_after.data // empty' 2>/dev/null)
test_result "Click returns screenshot" "$([ -n "$CLICK_OK" ] && echo true || echo false)"

SCROLL=$(api POST "/api/v1/tabs/${TAB_ID}/scroll" '{"x":640,"y":400,"scrolls":[{"delta_px":300,"direction":"y"}]}')
SCROLL_OK=$(echo "$SCROLL" | jq -r '.screenshot_after.data // empty' 2>/dev/null)
test_result "Scroll returns screenshot" "$([ -n "$SCROLL_OK" ] && echo true || echo false)"

WAIT=$(api POST "/api/v1/tabs/${TAB_ID}/wait" '{"ms":500}')
WAIT_OK=$(echo "$WAIT" | jq -r '.screenshot_after // .result // empty' 2>/dev/null)
test_result "Wait completes" "$([ -n "$WAIT_OK" ] && echo true || echo false)"

# -------------------------------------------------------------------
# 11. Bandwidth accumulation (second request should show session totals)
# -------------------------------------------------------------------
echo ""
echo "==> 11. Bandwidth Accumulation"
NAV2=$(api POST "/api/v1/tabs/${TAB_ID}/navigate" '{"url":"https://httpbin.org/html"}' 60)
SESSION2_RECV=$(echo "$NAV2" | jq -r '.network.session_bytes_received // "0"' 2>/dev/null)
ACTION2_RECV=$(echo "$NAV2" | jq -r '.network.bytes_received // "0"' 2>/dev/null)
test_result "Session bytes > action bytes (accumulated)" \
    "$(echo "$SESSION2_RECV $ACTION2_RECV" | awk '{print ($1 > $2) ? "true" : "false"}' 2>/dev/null)" \
    "session=$SESSION2_RECV action=$ACTION2_RECV"

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}ALL TESTS PASSED${NC}: ${PASS}/${TOTAL}"
else
    echo -e "  ${RED}FAILURES${NC}: ${FAIL}/${TOTAL} failed"
fi
echo "============================================================"

exit $FAIL
