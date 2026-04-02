#!/bin/bash
# Apply stealth edits directly to ABP source using sed/insertions.
# More robust than patch files — finds insertion points by anchor strings
# rather than exact line numbers.
#
# Usage: ./apply-stealth-edits.sh /path/to/src
set -euo pipefail

SRC="$1"

if [ ! -d "${SRC}/chrome/browser/abp" ]; then
    echo "ERROR: Not an ABP source tree: ${SRC}"
    exit 1
fi

APPLIED=0
SKIPPED=0

apply() {
    local file="$1"
    local desc="$2"
    local anchor="$3"
    local code="$4"
    local mode="${5:-after}"  # "after" or "before" the anchor line

    local fullpath="${SRC}/${file}"
    if [ ! -f "${fullpath}" ]; then
        echo "  SKIP ${desc} — file not found: ${file}"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    # Check if already applied (look for our marker comment)
    if grep -q "ABP stealth" "${fullpath}" 2>/dev/null; then
        echo "  SKIP ${desc} — already applied"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    # Check anchor exists
    if ! grep -qF "${anchor}" "${fullpath}"; then
        echo "  SKIP ${desc} — anchor not found: ${anchor}"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    # Apply edit
    if [ "${mode}" = "before" ]; then
        sed -i "/${anchor}/i\\${code}" "${fullpath}" 2>/dev/null || \
        python3 -c "
import re, sys
with open('${fullpath}', 'r') as f: content = f.read()
anchor = '''${anchor}'''
insert = '''${code}'''
idx = content.find(anchor)
if idx >= 0:
    with open('${fullpath}', 'w') as f: f.write(content[:idx] + insert + '\n' + content[idx:])
"
    else
        sed -i "/${anchor}/a\\${code}" "${fullpath}" 2>/dev/null || \
        python3 -c "
import sys
with open('${fullpath}', 'r') as f: content = f.read()
anchor = '''${anchor}'''
insert = '''${code}'''
idx = content.find(anchor)
if idx >= 0:
    end = content.index('\n', idx) + 1
    with open('${fullpath}', 'w') as f: f.write(content[:end] + insert + '\n' + content[end:])
"
    fi

    echo "  OK   ${desc}"
    APPLIED=$((APPLIED + 1))
}

echo "==> Applying stealth edits to ABP source..."
echo ""

# ===================================================================
# Edit 1: navigator.webdriver — always return false
# ===================================================================
# This is the simplest and most impactful edit.
# Find Navigator::webdriver() and make it return false when
# --abp-fingerprint is set.

WEBDRIVER_FILE="third_party/blink/renderer/core/frame/navigator.cc"
if [ -f "${SRC}/${WEBDRIVER_FILE}" ]; then
    # Use python for complex multi-line edits
    python3 << PYEOF
import re

filepath = "${SRC}/${WEBDRIVER_FILE}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP stealth' in content:
    print("  SKIP navigator.webdriver — already applied")
else:
    # Add include
    if '#include "base/command_line.h"' not in content:
        content = content.replace(
            '#include "third_party/blink/renderer/core/frame/navigator.h"',
            '#include "third_party/blink/renderer/core/frame/navigator.h"\n#include "base/command_line.h"',
            1
        )

    # Find webdriver() method and inject early return
    # Look for the function that returns webdriver status
    patterns = [
        'bool Navigator::webdriver()',
        'bool NavigatorAutomationInformation::webdriver(',
    ]
    for pat in patterns:
        if pat in content:
            idx = content.find(pat)
            # Find the opening brace
            brace = content.find('{', idx)
            if brace > 0:
                inject = """
  // ABP stealth: always report non-automated.
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("abp-fingerprint"))
    return false;
"""
                content = content[:brace+1] + inject + content[brace+1:]
                print("  OK   navigator.webdriver = false")
                break
    else:
        print("  SKIP navigator.webdriver — function not found")

    with open(filepath, 'w') as f:
        f.write(content)
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP navigator.webdriver — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

# ===================================================================
# Edit 2: navigator.plugins — populate in headless
# ===================================================================
PLUGINS_FILE="third_party/blink/renderer/modules/plugins/dom_plugin_array.cc"
if [ -f "${SRC}/${PLUGINS_FILE}" ]; then
    python3 << PYEOF
filepath = "${SRC}/${PLUGINS_FILE}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP stealth' in content:
    print("  SKIP navigator.plugins — already applied")
else:
    # Add command_line include
    if '#include "base/command_line.h"' not in content:
        # Insert after the first #include
        idx = content.find('#include')
        endline = content.find('\n', idx) + 1
        content = content[:endline] + '#include "base/command_line.h"\n' + content[endline:]

    # Find IsPdfViewerAvailable check and add our override
    target = 'IsPdfViewerAvailable()'
    if target in content:
        # Replace the condition to also check our flag
        content = content.replace(
            'if (IsPdfViewerAvailable())',
            '// ABP stealth: force-populate plugins in headless mode.\n'
            '  if (base::CommandLine::ForCurrentProcess()->HasSwitch("abp-fingerprint") || IsPdfViewerAvailable())',
            1
        )
        print("  OK   navigator.plugins — force populate")
    else:
        print("  SKIP navigator.plugins — anchor not found")

    with open(filepath, 'w') as f:
        f.write(content)
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP navigator.plugins — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

# ===================================================================
# Edit 3: User-Agent — remove "Headless" from product string
# ===================================================================
# The UA string "HeadlessChrome/146.0.0.0" comes from the product name
# set when headless mode is active. We need to find where "Headless" is
# prepended to the product name and remove it. We also search multiple
# files since different Chromium versions put this in different places.
echo -n "  user-agent... "
UA_FIXED=0
for UA_FILE in \
    "content/common/user_agent.cc" \
    "components/embedder_support/user_agent_utils.cc" \
    "headless/lib/browser/headless_content_browser_client.cc" \
    "chrome/common/chrome_content_client.cc" \
    "content/shell/common/shell_content_client.cc"; do

    [ ! -f "${SRC}/${UA_FILE}" ] && continue

    python3 << PYEOF
import re

filepath = "${SRC}/${UA_FILE}"
with open(filepath, 'r') as f:
    content = f.read()

modified = False

# Strategy 1: Replace literal "HeadlessChrome" with "Chrome"
if 'HeadlessChrome' in content:
    content = content.replace('HeadlessChrome', 'Chrome')
    modified = True
    print(f"    Replaced HeadlessChrome in ${UA_FILE}")

# Strategy 2: Replace "Headless" + product concatenation patterns
# e.g., "Headless" + product or "Headless" being prepended
for pattern in ['"Headless"', "'Headless'", 'kHeadless']:
    if pattern in content and 'ABP stealth' not in content:
        # Comment out or replace the headless prefix
        content = content.replace(pattern, '""  // ABP stealth: removed Headless prefix')
        modified = True
        print(f"    Removed headless prefix in ${UA_FILE}")
        break

if modified:
    with open(filepath, 'w') as f:
        f.write(content)
PYEOF
    UA_FIXED=$((UA_FIXED + 1))
done

# Also do a brute-force search across the whole source for "HeadlessChrome"
grep -rl "HeadlessChrome" "${SRC}/components/" "${SRC}/content/" "${SRC}/headless/" "${SRC}/chrome/" 2>/dev/null | while read -r f; do
    sed -i 's/HeadlessChrome/Chrome/g' "$f" 2>/dev/null && echo "    Fixed HeadlessChrome in $(basename $f)"
done || true

# Also search for the headless product name construction
grep -rl '"Headless"' "${SRC}/headless/" "${SRC}/content/" 2>/dev/null | head -5 | while read -r f; do
    python3 << PYEOF2
filepath = "$f"
with open(filepath, 'r') as fh:
    content = fh.read()
if 'ABP stealth' not in content and '"Headless"' in content:
    # Replace "Headless" string used in product name with empty
    import re
    content = re.sub(r'(product\s*=\s*)"Headless"\s*\+', r'\1""  /* ABP stealth */ +', content)
    content = re.sub(r'"Headless"\s*\+\s*', '/* ABP stealth removed Headless */ ', content)
    with open(filepath, 'w') as fh:
        fh.write(content)
    print(f"    Patched headless product in $(basename $f)")
PYEOF2
done || true

echo "OK (searched and replaced across source tree)"
APPLIED=$((APPLIED + 1))

# ===================================================================
# Edit 4: window.outerWidth/outerHeight — realistic values
# ===================================================================
WINDOW_FILE="third_party/blink/renderer/core/frame/local_dom_window.cc"
if [ -f "${SRC}/${WINDOW_FILE}" ]; then
    python3 << PYEOF
filepath = "${SRC}/${WINDOW_FILE}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP stealth' in content:
    print("  SKIP window dimensions — already applied")
else:
    if '#include "base/command_line.h"' not in content:
        idx = content.find('#include')
        endline = content.find('\n', idx) + 1
        content = content[:endline] + '#include "base/command_line.h"\n' + content[endline:]

    # Find outerHeight function
    for func_name in ['LocalDOMWindow::outerHeight', 'DOMWindow::outerHeight']:
        if func_name in content:
            idx = content.find(func_name)
            brace = content.find('{', idx)
            if brace > 0:
                inject = """
  // ABP stealth: return realistic outerHeight (innerHeight + toolbar).
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("abp-fingerprint")) {
    int inner = innerHeight();
    if (inner > 0) return inner + 87;  // Windows Chrome toolbar height
  }
"""
                content = content[:brace+1] + inject + content[brace+1:]
                print(f"  OK   window.outerHeight — injected")
                break

    for func_name in ['LocalDOMWindow::outerWidth', 'DOMWindow::outerWidth']:
        if func_name in content:
            idx = content.find(func_name)
            brace = content.find('{', idx)
            if brace > 0:
                inject = """
  // ABP stealth: return realistic outerWidth.
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("abp-fingerprint")) {
    int inner = innerWidth();
    if (inner > 0) return inner + 16;  // Windows Chrome side borders
  }
"""
                content = content[:brace+1] + inject + content[brace+1:]
                print(f"  OK   window.outerWidth — injected")
                break

    with open(filepath, 'w') as f:
        f.write(content)
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP window dimensions — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

# ===================================================================
# Edit 5: Remove automation flags at startup
# ===================================================================
MAIN_FILE="chrome/browser/chrome_browser_main.cc"
if [ -f "${SRC}/${MAIN_FILE}" ]; then
    python3 << PYEOF
filepath = "${SRC}/${MAIN_FILE}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP stealth' in content:
    print("  SKIP automation flags — already applied")
else:
    # Find ABP's existing hook (no-first-run) and add stealth flag cleanup after it
    anchor = 'no-first-run'
    if anchor in content:
        idx = content.find(anchor)
        endline = content.find('\n', idx) + 1
        # Find the next line end after the no-first-run line
        next_endline = content.find('\n', endline) + 1

        inject = """
  // ABP stealth: add anti-detection flag.
  if (command_line->HasSwitch("abp-fingerprint")) {
    command_line->AppendSwitchASCII("disable-blink-features", "AutomationControlled");
  }
"""
        content = content[:next_endline] + inject + content[next_endline:]
        print("  OK   automation flags — injected at startup")
    else:
        print("  SKIP automation flags — anchor not found")

    with open(filepath, 'w') as f:
        f.write(content)
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP automation flags — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

# ===================================================================
# Edit 6: WebGL vendor/renderer spoofing
# ===================================================================
WEBGL_FILE="third_party/blink/renderer/modules/webgl/webgl_rendering_context_base.cc"
if [ -f "${SRC}/${WEBGL_FILE}" ]; then
    python3 << PYEOF
filepath = "${SRC}/${WEBGL_FILE}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP stealth' in content:
    print("  SKIP webgl spoofing — already applied")
else:
    # Add include
    if '#include "base/command_line.h"' not in content:
        idx = content.find('#include')
        endline = content.find('\n', idx) + 1
        content = content[:endline] + '#include "base/command_line.h"\n' + content[endline:]

    # Find where UNMASKED_VENDOR_WEBGL is handled
    # Look for the GL_VENDOR getString call near kUnmaskedVendorWebgl
    vendor_marker = 'UNMASKED_VENDOR_WEBGL'
    renderer_marker = 'UNMASKED_RENDERER_WEBGL'

    if vendor_marker in content:
        # Find the case/if block for vendor
        idx = content.find(vendor_marker)
        # Find the next GetString(GL_VENDOR) or getString call after it
        get_str = content.find('GetString', idx)
        if get_str > 0:
            # Find the line start before GetString
            line_start = content.rfind('\n', 0, get_str) + 1
            inject = """        // ABP stealth: spoof WebGL vendor.
        if (base::CommandLine::ForCurrentProcess()->HasSwitch("abp-fingerprint")) {
          return WebGLAny(script_state, String("Google Inc. (NVIDIA)"));
        }
"""
            content = content[:line_start] + inject + content[line_start:]
            print("  OK   webgl vendor spoofed")

    # Re-find renderer marker (content shifted after vendor inject)
    if renderer_marker in content:
        idx = content.find(renderer_marker)
        get_str = content.find('GetString', idx)
        if get_str > 0:
            line_start = content.rfind('\n', 0, get_str) + 1
            inject = """        // ABP stealth: spoof WebGL renderer.
        if (base::CommandLine::ForCurrentProcess()->HasSwitch("abp-fingerprint")) {
          return WebGLAny(script_state, String("ANGLE (NVIDIA, NVIDIA GeForce RTX 3070 Direct3D11 vs_5_0 ps_5_0, D3D11)"));
        }
"""
            content = content[:line_start] + inject + content[line_start:]
            print("  OK   webgl renderer spoofed")

    with open(filepath, 'w') as f:
        f.write(content)
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP webgl spoofing — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

# ===================================================================
# Edit 7: navigator.platform — match spoofed platform
# ===================================================================
NAVIGATOR_FILE="third_party/blink/renderer/core/frame/navigator.cc"
if [ -f "${SRC}/${NAVIGATOR_FILE}" ]; then
    python3 << PYEOF
filepath = "${SRC}/${NAVIGATOR_FILE}"
with open(filepath, 'r') as f:
    content = f.read()

# Only apply if not already done (check for platform spoof specifically)
if 'ABP stealth: spoof platform' in content:
    print("  SKIP navigator.platform — already applied")
else:
    for pat in ['Navigator::platform()', 'NavigatorID::platform(']:
        if pat in content:
            idx = content.find(pat)
            brace = content.find('{', idx)
            if brace > 0:
                inject = """
  // ABP stealth: spoof platform to match claimed OS.
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("abp-fingerprint")) {
    std::string plat = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("abp-fingerprint-platform");
    if (plat == "windows") return "Win32";
    if (plat == "macos") return "MacIntel";
  }
"""
                content = content[:brace+1] + inject + content[brace+1:]
                print("  OK   navigator.platform spoofed")
                break

    with open(filepath, 'w') as f:
        f.write(content)
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP navigator.platform — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

echo ""
echo "==> Stealth edits complete. Applied: ${APPLIED}, Skipped: ${SKIPPED}"
