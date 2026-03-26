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
# Edit 3: User-Agent — remove HeadlessChrome
# ===================================================================
UA_FILE="components/embedder_support/user_agent_utils.cc"
if [ -f "${SRC}/${UA_FILE}" ]; then
    python3 << PYEOF
filepath = "${SRC}/${UA_FILE}"
with open(filepath, 'r') as f:
    content = f.read()

if 'ABP stealth' in content:
    print("  SKIP user-agent — already applied")
else:
    if '#include "base/command_line.h"' not in content:
        idx = content.find('#include')
        endline = content.find('\n', idx) + 1
        content = content[:endline] + '#include "base/command_line.h"\n' + content[endline:]

    # Find BuildUserAgentFromProduct or GetUserAgent and inject platform override
    for func in ['BuildOSCpuInfoFromOSVersionAndCpuType', 'GetOSType', 'GetPlatformForUAString']:
        if func in content:
            idx = content.find(func)
            brace = content.find('{', idx)
            if brace > 0:
                inject = """
  // ABP stealth: override OS info in UA string.
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("abp-fingerprint")) {
    std::string platform = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("abp-fingerprint-platform");
    if (platform == "windows") return "Windows NT 10.0; Win64; x64";
    if (platform == "macos") return "Macintosh; Intel Mac OS X 10_15_7";
  }
"""
                content = content[:brace+1] + inject + content[brace+1:]
                print(f"  OK   user-agent — injected at {func}")
                break
    else:
        print("  SKIP user-agent — no suitable function found")

    with open(filepath, 'w') as f:
        f.write(content)
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP user-agent — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

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

echo ""
echo "==> Stealth edits complete. Applied: ${APPLIED}, Skipped: ${SKIPPED}"
echo ""
echo "NOTE: The following advanced patches require more complex changes"
echo "and should be applied manually after verifying the build works:"
echo "  - WebGL vendor/renderer spoofing (006)"
echo "  - Canvas/WebGL pixel noise (007-009)"
echo "  - Audio fingerprint noise (010)"
echo "  - Font enumeration filtering (011)"
echo "  - Client rects / measureText noise (013-014)"
echo "  - Timezone override (015)"
echo "  - Runtime.enable neutralization (003)"
echo ""
echo "These 5 core edits (webdriver, plugins, UA, window size, flags)"
echo "cover the most impactful detection vectors for an initial build."
