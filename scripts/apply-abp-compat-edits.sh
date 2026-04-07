#!/bin/bash
# Apply compatibility edits to ABP protocol source for Chromium 142.
#
# Usage: ./scripts/apply-abp-compat-edits.sh /path/to/chromium/src
set -euo pipefail

SRC_DIR="${1:?Usage: $0 <chromium-src-dir>}"
ABP_DIR="${SRC_DIR}/chrome/browser/abp"

if [ ! -d "${ABP_DIR}" ]; then
    echo "  SKIP — ABP directory not found at ${ABP_DIR}"
    exit 0
fi

echo "==> Applying ABP Chromium 142 compatibility edits..."

APPLIED=0
SKIPPED=0

# ---------------------------------------------------------------------------
# Fix 1: Add "ABP" to sql::Database::Tag whitelist
#
# Chromium 142 uses a consteval Tag that validates against a hardcoded list.
# We leave the ABP source unchanged and instead add "ABP" to the whitelist
# in sql/database.h. We find the Tag consteval constructor and add our tag
# before the NOTREACHED/validation failure line.
# ---------------------------------------------------------------------------
SQL_DB_H="${SRC_DIR}/sql/database.h"
if [ -f "${SQL_DB_H}" ]; then
    if grep -q '"ABP"' "${SQL_DB_H}"; then
        echo "  SKIP  ABP already in sql::Database::Tag whitelist"
        SKIPPED=$((SKIPPED + 1))
    else
        echo "  Adding ABP to sql::Database::Tag whitelist..."
        # The Tag class has a consteval constructor that validates known tags.
        # We need to find it and add "ABP". Strategy: search for the pattern
        # where known tags are listed and add ours.
        python3 - "${SQL_DB_H}" <<'PYEOF'
import sys, re

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if '"ABP"' in content:
    print("  ABP already present")
    sys.exit(0)

# Strategy 1: Find the consteval Tag constructor body.
# It typically has a series of string comparisons or a validation function.
# Look for patterns like: if (tag == "SomeTag") return;
# or NOTREACHED / "Invalid database tag"

# First try: find "Invalid database tag" diagnostic
invalid_idx = content.find('Invalid database tag')
if invalid_idx < 0:
    # Try alternate patterns
    invalid_idx = content.find('NOTREACHED')
    if invalid_idx < 0:
        # Try finding the consteval constructor
        match = re.search(r'consteval\s+Tag\s*\(', content)
        if match:
            # Find the opening brace of the constructor body
            brace_start = content.find('{', match.end())
            if brace_start >= 0:
                # Extract the actual parameter name from the constructor signature
                sig = content[match.end():brace_start]
                param_match = re.search(r'(\w+)\s*\)\s*(?:noexcept\s*)?$', sig.strip())
                _ctor_param = param_match.group(1) if param_match else None
                invalid_idx = brace_start + 1  # Insert at start of body
        else:
            print("  WARN  Could not find Tag validation in sql/database.h")
            # Last resort: find 'class Tag' and dump context for debugging
            tag_class = content.find('class Tag')
            if tag_class >= 0:
                print("  Context around 'class Tag':")
                print(content[tag_class:tag_class+500])
            sys.exit(0)

# Walk backwards to find the start of the line
line_start = content.rfind('\n', 0, invalid_idx) + 1

# Detect indentation
rest = content[line_start:]
indent = ''
for ch in rest:
    if ch in (' ', '\t'):
        indent += ch
    else:
        break
if not indent:
    indent = '      '

# Insert an ABP tag check. We use string comparison that works in consteval.
# Try to match the style of existing checks in the file.
# Look backwards for an existing check pattern to match style.
preceding = content[max(0, line_start-500):line_start]

# Determine the parameter name: prefer what we extracted from the constructor
# signature; fall back to scanning the surrounding code for a known name.
param_name = locals().get('_ctor_param') or None
if param_name is None:
    # Scan preceding context for an identifier used in comparisons
    m = re.search(r'(\w+)\s*==\s*"', preceding)
    param_name = m.group(1) if m else 'tag'

if 'strcmp' in preceding or f'{param_name} ==' in preceding or 'tag ==' in preceding:
    # Uses == style
    check = f'{indent}if ({param_name} == "ABP") return;\n'
elif 'operator()' in preceding:
    # Might be a functor pattern
    check = f'{indent}if ({param_name} == "ABP") return;\n'
else:
    # Char-by-char comparison using the extracted parameter name
    p = param_name
    check = f'{indent}if ({p}[0] == \'A\' && {p}[1] == \'B\' && {p}[2] == \'P\' && {p}[3] == \'\\0\') return;\n'

content = content[:line_start] + check + content[line_start:]

with open(filepath, 'w') as f:
    f.write(content)
print("  OK   added ABP to Tag whitelist in sql/database.h")
PYEOF
        APPLIED=$((APPLIED + 1))

        # Undo any prior sed-based Tag removal from ABP files that broke
        # the make_unique call. Re-fetch clean ABP source if needed.
    fi
else
    echo "  SKIP  sql/database.h not found"
    SKIPPED=$((SKIPPED + 1))
fi

# Verify the ABP database files still have the original Tag("ABP") call.
# If a prior compat edit removed it, restore it.
for db_file in "${ABP_DIR}/abp_network_database.cc" "${ABP_DIR}/abp_history_database.cc"; do
    if [ ! -f "${db_file}" ]; then
        continue
    fi
    fname="$(basename "${db_file}")"
    if ! grep -q 'sql::Database::Tag(' "${db_file}"; then
        echo "  WARN  ${fname} is missing Tag() call — re-fetching from ABP source..."
        # The compat script from a prior run mangled this file.
        # Re-copy from the ABP extract if available.
        ABP_EXTRACT="/root/abp-source"
        orig="${ABP_EXTRACT}/chrome/browser/abp/${fname}"
        if [ -f "${orig}" ]; then
            cp "${orig}" "${db_file}"
            echo "  OK   restored ${fname} from ABP source"
        else
            echo "  FAIL  cannot restore ${fname} — ABP source not available"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Fix 2: ui::mojom::CursorType incomplete type in abp_controller.h
# ---------------------------------------------------------------------------
CONTROLLER_H="${ABP_DIR}/abp_controller.h"
if [ -f "${CONTROLLER_H}" ]; then
    if grep -q 'cursor_type.mojom-forward.h' "${CONTROLLER_H}"; then
        sed -i 's|cursor_type.mojom-forward.h|cursor_type.mojom-shared.h|' "${CONTROLLER_H}"
        echo "  OK   fixed CursorType include in abp_controller.h"
        APPLIED=$((APPLIED + 1))
    else
        echo "  SKIP  CursorType include already fixed in abp_controller.h"
        SKIPPED=$((SKIPPED + 1))
    fi
fi

# ---------------------------------------------------------------------------
# Fix 3: Missing kAbpHumanIcon, kAbpCdpIcon, kAbpRobotIcon
# ---------------------------------------------------------------------------
ICON_VIEW="${ABP_DIR}/abp_input_mode_icon_view.cc"
if [ -f "${ICON_VIEW}" ]; then
    if grep -q 'VECTOR_ICON_STUB_ABP' "${ICON_VIEW}"; then
        echo "  SKIP  icon stubs already present in abp_input_mode_icon_view.cc"
        SKIPPED=$((SKIPPED + 1))
    elif grep -q 'kAbpHumanIcon' "${ICON_VIEW}"; then
        python3 -c "
import sys
p = '${ICON_VIEW}'
lines = open(p).readlines()
last_inc = 0
for i, l in enumerate(lines):
    if l.strip().startswith('#include'):
        last_inc = i
stub = '''
// VECTOR_ICON_STUB_ABP — Chromium 142 compat: ABP icons not in vector_icons.h
#include \"ui/gfx/vector_icon_types.h\"
namespace {
const gfx::PathElement kAbpStubPath[] = {{gfx::CommandType::CLOSE}};
const gfx::VectorIconRep kAbpStubRep[] = {{kAbpStubPath}};
const gfx::VectorIcon kAbpHumanIcon = {kAbpStubRep, \"abp_human\"};
const gfx::VectorIcon kAbpCdpIcon = {kAbpStubRep, \"abp_cdp\"};
const gfx::VectorIcon kAbpRobotIcon = {kAbpStubRep, \"abp_robot\"};
}  // namespace
'''
lines.insert(last_inc + 1, stub)
open(p, 'w').writelines(lines)
print('  OK   added icon stubs to abp_input_mode_icon_view.cc')
"
        APPLIED=$((APPLIED + 1))
    else
        echo "  SKIP  no kAbpHumanIcon reference in abp_input_mode_icon_view.cc"
        SKIPPED=$((SKIPPED + 1))
    fi
fi

echo "==> ABP compat edits complete. Applied: ${APPLIED}, Skipped: ${SKIPPED}"
