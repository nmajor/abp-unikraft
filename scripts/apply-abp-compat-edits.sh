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

# Step 1: Always extract the parameter name from the consteval Tag constructor
# signature first, before hunting for the injection point. This avoids the
# prior bug where branches 1/2 skipped param extraction entirely and fell
# back to the literal string 'tag' (which is undeclared in many TUs).
param_name = None
ctor_match = re.search(r'consteval\s+Tag\s*\(([^)]*)\)', content)
if ctor_match:
    sig = ctor_match.group(1)
    # Match: [const char* name] or [std::string_view name] or just [const char* name]
    pm = re.search(r'[\w:]+\s*\*?\s*(\w+)\s*$', sig.strip())
    if pm:
        param_name = pm.group(1)

# Step 2: Find the injection point — the line just before the validation failure.
invalid_idx = content.find('Invalid database tag')
if invalid_idx < 0:
    invalid_idx = content.find('NOTREACHED')
if invalid_idx < 0:
    # Fall back: inject at the opening brace of the constructor body
    if ctor_match:
        brace_start = content.find('{', ctor_match.end())
        if brace_start >= 0:
            invalid_idx = brace_start + 1
if invalid_idx < 0:
    print("  WARN  Could not find Tag validation in sql/database.h")
    tag_class = content.find('class Tag')
    if tag_class >= 0:
        print("  Context around 'class Tag':")
        print(content[tag_class:tag_class+500])
    sys.exit(0)

# Step 3: If we still have no param name, scan preceding context as last resort.
if param_name is None:
    line_start_tmp = content.rfind('\n', 0, invalid_idx) + 1
    preceding = content[max(0, line_start_tmp - 500):line_start_tmp]
    m = re.search(r'(\w+)\s*==\s*"', preceding)
    if m:
        param_name = m.group(1)

if not param_name:
    print("  WARN  Could not determine Tag constructor parameter name; dumping context:")
    if ctor_match:
        print(content[ctor_match.start():ctor_match.start()+300])
    sys.exit(1)

# Walk backwards to find the start of the line for indentation.
line_start = content.rfind('\n', 0, invalid_idx) + 1
rest = content[line_start:]
indent = ''
for ch in rest:
    if ch in (' ', '\t'):
        indent += ch
    else:
        break
if not indent:
    indent = '      '

# Use simple == comparison (works in consteval C++20 with const char* and string_view).
check = f'{indent}if ({param_name} == "ABP") return;\n'

content = content[:line_start] + check + content[line_start:]

with open(filepath, 'w') as f:
    f.write(content)
print(f"  OK   added ABP to Tag whitelist in sql/database.h (param: {param_name})")
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
