#!/bin/bash
# Apply stealth-extra edits to a fingerprint-chromium source tree.
#
# These cover detection surfaces that fingerprint-chromium does NOT patch:
#   1. window.outerWidth/outerHeight (headless returns 0)
#   2. Pointer/hover media queries (headless returns none) — CRITICAL for DataDome
#   3. screen.width/height/colorDepth/availWidth/availHeight
#   4. navigator.deviceMemory (server RAM leak)
#   5. Automation flag removal (comprehensive)
#
# Uses --fingerprint (fingerprint-chromium's master switch) for activation.
#
# Usage: ./apply-stealth-extra-edits.sh /path/to/chromium-src
set -euo pipefail

SRC="$1"

if [ ! -d "${SRC}/third_party/blink" ]; then
    echo "ERROR: Not a Chromium source tree: ${SRC}"
    exit 1
fi

APPLIED=0
SKIPPED=0

echo "==> Applying stealth-extra edits (fingerprint-chromium gaps)..."
echo ""

# ===================================================================
# Edit 1: window.outerWidth/outerHeight — realistic values
# ===================================================================
WINDOW_FILE="${SRC}/third_party/blink/renderer/core/frame/local_dom_window.cc"
if [ -f "${WINDOW_FILE}" ]; then
    python3 - "${WINDOW_FILE}" << 'PYEOF'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'stealth-extra' in content:
    print("  SKIP window dimensions — already applied")
    sys.exit(0)

if '#include "base/command_line.h"' not in content:
    idx = content.find('#include')
    endline = content.find('\n', idx) + 1
    content = content[:endline] + '#include "base/command_line.h"\n' + content[endline:]

modified = False

for func_name in ['LocalDOMWindow::outerHeight', 'DOMWindow::outerHeight']:
    if func_name in content:
        idx = content.find(func_name)
        brace = content.find('{', idx)
        if brace > 0:
            inject = '\n  // stealth-extra: realistic outerHeight (innerHeight + toolbar).\n  if (base::CommandLine::ForCurrentProcess()->HasSwitch("fingerprint")) {\n    int inner = innerHeight();\n    if (inner > 0) return inner + 87;\n  }\n'
            content = content[:brace+1] + inject + content[brace+1:]
            modified = True
            print("  OK   window.outerHeight")
            break

for func_name in ['LocalDOMWindow::outerWidth', 'DOMWindow::outerWidth']:
    if func_name in content:
        idx = content.find(func_name)
        brace = content.find('{', idx)
        if brace > 0:
            inject = '\n  // stealth-extra: realistic outerWidth.\n  if (base::CommandLine::ForCurrentProcess()->HasSwitch("fingerprint")) {\n    int inner = innerWidth();\n    if (inner > 0) return inner + 16;\n  }\n'
            content = content[:brace+1] + inject + content[brace+1:]
            modified = True
            print("  OK   window.outerWidth")
            break

if modified:
    with open(filepath, 'w') as f:
        f.write(content)
else:
    print("  SKIP window dimensions — anchor not found")
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP window dimensions — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

# ===================================================================
# Edit 2: Pointer/hover media queries — CRITICAL for DataDome
# ===================================================================
MEDIA_FILE="${SRC}/third_party/blink/renderer/core/css/media_query_evaluator.cc"
if [ -f "${MEDIA_FILE}" ]; then
    python3 - "${MEDIA_FILE}" << 'PYEOF'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'stealth-extra' in content:
    print("  SKIP pointer/hover — already applied")
    sys.exit(0)

if '#include "base/command_line.h"' not in content:
    idx = content.find('#include')
    endline = content.find('\n', idx) + 1
    content = content[:endline] + '#include "base/command_line.h"\n' + content[endline:]

modified = False

# Fix pointer: headless returns 0 (POINTER_TYPE_NONE)
for func in ['AnyPointerMediaFeatureEval', 'PointerMediaFeatureEval']:
    if func in content:
        idx = content.find(func)
        avail = content.find('GetAvailablePointerTypes()', idx)
        if avail > 0 and avail - idx < 500:
            eol = content.find(';', avail)
            next_line = content.find('\n', eol) + 1
            inject = '\n  // stealth-extra: force POINTER_TYPE_FINE in headless (DataDome Device Check).\n  if (base::CommandLine::ForCurrentProcess()->HasSwitch("fingerprint") && available == 0) {\n    available = 1;\n  }\n'
            content = content[:next_line] + inject + content[next_line:]
            modified = True
            print("  OK   pointer media query = fine")
            break

# Fix hover: headless returns 0 (HOVER_TYPE_NONE)
for func in ['AnyHoverMediaFeatureEval', 'HoverMediaFeatureEval']:
    if func in content:
        idx = content.find(func)
        avail = content.find('GetAvailableHoverTypes()', idx)
        if avail > 0 and avail - idx < 500:
            eol = content.find(';', avail)
            next_line = content.find('\n', eol) + 1
            inject = '\n  // stealth-extra: force HOVER_TYPE_HOVER in headless.\n  if (base::CommandLine::ForCurrentProcess()->HasSwitch("fingerprint") && available == 0) {\n    available = 1;\n  }\n'
            content = content[:next_line] + inject + content[next_line:]
            modified = True
            print("  OK   hover media query = hover")
            break

if modified:
    with open(filepath, 'w') as f:
        f.write(content)
else:
    print("  SKIP pointer/hover — anchor not found")
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP pointer/hover — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

# ===================================================================
# Edit 3: screen.width/height/colorDepth/availWidth/availHeight
# ===================================================================
SCREEN_FILE="${SRC}/third_party/blink/renderer/core/frame/screen.cc"
if [ -f "${SCREEN_FILE}" ]; then
    python3 - "${SCREEN_FILE}" << 'PYEOF'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'stealth-extra' in content:
    print("  SKIP screen properties — already applied")
    sys.exit(0)

if '#include "base/command_line.h"' not in content:
    idx = content.find('#include')
    endline = content.find('\n', idx) + 1
    content = content[:endline] + '#include "base/command_line.h"\n' + content[endline:]

overrides = [
    ('Screen::height()',      1080, 'screen.height'),
    ('Screen::width()',       1920, 'screen.width'),
    ('Screen::colorDepth()',    24, 'screen.colorDepth'),
    ('Screen::availHeight()', 1040, 'screen.availHeight'),
    ('Screen::availWidth()',  1920, 'screen.availWidth'),
]

modified = False
for func_sig, value, desc in overrides:
    if func_sig in content:
        idx = content.find(func_sig)
        brace = content.find('{', idx)
        if brace > 0:
            inject = f'\n  // stealth-extra: {desc}.\n  if (base::CommandLine::ForCurrentProcess()->HasSwitch("fingerprint"))\n    return {value};\n'
            content = content[:brace+1] + inject + content[brace+1:]
            modified = True
            print(f"  OK   {desc} = {value}")

if modified:
    with open(filepath, 'w') as f:
        f.write(content)
else:
    print("  SKIP screen properties — anchor not found")
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP screen properties — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

# ===================================================================
# Edit 4: navigator.deviceMemory — hide server RAM
# ===================================================================
DEVMEM_FILE="${SRC}/third_party/blink/renderer/core/frame/navigator_device_memory.cc"
if [ -f "${DEVMEM_FILE}" ]; then
    python3 - "${DEVMEM_FILE}" << 'PYEOF'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'stealth-extra' in content:
    print("  SKIP deviceMemory — already applied")
    sys.exit(0)

if '#include "base/command_line.h"' not in content:
    idx = content.find('#include')
    endline = content.find('\n', idx) + 1
    content = content[:endline] + '#include "base/command_line.h"\n' + content[endline:]

for func in ['NavigatorDeviceMemory::deviceMemory()', 'deviceMemory() const']:
    if func in content:
        idx = content.find(func)
        brace = content.find('{', idx)
        if brace > 0:
            inject = '\n  // stealth-extra: return 8GB (realistic consumer value).\n  if (base::CommandLine::ForCurrentProcess()->HasSwitch("fingerprint"))\n    return 8.0f;\n'
            content = content[:brace+1] + inject + content[brace+1:]
            with open(filepath, 'w') as f:
                f.write(content)
            print("  OK   deviceMemory = 8GB")
            break
else:
    print("  SKIP deviceMemory — anchor not found")
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP deviceMemory — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

# ===================================================================
# Edit 5: Remove automation flags at startup
# ===================================================================
MAIN_FILE="${SRC}/chrome/browser/chrome_browser_main.cc"
if [ -f "${MAIN_FILE}" ]; then
    python3 - "${MAIN_FILE}" << 'PYEOF'
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'stealth-extra' in content:
    print("  SKIP automation flags — already applied")
    sys.exit(0)

for anchor in ['PreMainMessageLoopRunImpl', 'no-first-run', 'PreMainMessageLoopRun']:
    if anchor in content:
        idx = content.find(anchor)
        eol = content.find('\n', idx)
        next_eol = content.find('\n', eol + 1)
        inject = """
  // stealth-extra: clean up automation signals.
  {
    auto* cl = base::CommandLine::ForCurrentProcess();
    if (cl->HasSwitch("fingerprint")) {
      static const char* const kFlags[] = {
        "enable-automation", "disable-component-update",
        "disable-default-apps", "disable-extensions",
        "disable-popup-blocking", "metrics-recording-only",
        "disable-back-forward-cache", "disable-ipc-flooding-protection",
      };
      for (const char* flag : kFlags) cl->RemoveSwitch(flag);
      cl->AppendSwitchASCII("disable-blink-features", "AutomationControlled");
    }
  }
"""
        content = content[:next_eol+1] + inject + content[next_eol+1:]
        with open(filepath, 'w') as f:
            f.write(content)
        print("  OK   automation flags removed")
        break
else:
    print("  SKIP automation flags — anchor not found")
PYEOF
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP automation flags — file not found"
    SKIPPED=$((SKIPPED + 1))
fi

echo ""
echo "==> Stealth-extra edits complete. Applied: ${APPLIED}, Skipped: ${SKIPPED}"
echo ""
echo "Surfaces patched (fingerprint-chromium gaps):"
echo "  - window.outerWidth/outerHeight"
echo "  - (pointer: fine) / (hover: hover) — DataDome Device Check"
echo "  - screen.width/height/colorDepth/availWidth/availHeight"
echo "  - navigator.deviceMemory = 8GB"
echo "  - Automation flag removal"
