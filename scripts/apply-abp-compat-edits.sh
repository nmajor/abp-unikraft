#!/bin/bash
# Apply compatibility edits to ABP protocol source for Chromium 142.
#
# ABP was developed against an older Chromium version. These edits fix
# API changes in Chromium 142 that break compilation:
#
# 1. sql::Database::Tag("ABP") — "ABP" not in consteval whitelist;
#    register it in sql/database.h.
# 2. ui::mojom::CursorType incomplete — add full mojom include to
#    abp_controller.h.
# 3. kAbpHumanIcon etc. undeclared — define stub VectorIcon constants
#    in abp_input_mode_icon_view.cc.
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
# Fix 1: sql::Database constructor — avoid consteval Tag entirely
#
# In Chromium 142, sql::Database::Tag is consteval with a hardcoded whitelist.
# "ABP" isn't in the whitelist. Rather than patching the core sql/database.h
# header (which breaks the entire build), we replace the ABP database
# constructor calls with the simpler Database(DatabaseOptions) overload that
# doesn't require a Tag at all.
# ---------------------------------------------------------------------------
for db_file in "${ABP_DIR}/abp_network_database.cc" "${ABP_DIR}/abp_history_database.cc"; do
    if [ ! -f "${db_file}" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if grep -q 'sql::Database::Tag("ABP")' "${db_file}"; then
        # Remove the Tag("ABP") argument from the Database constructor.
        # Before: Database(DatabaseOptions()..., Tag("ABP"))
        # After:  Database(DatabaseOptions()...)
        sed -i '/sql::Database::Tag("ABP")/d' "${db_file}"
        # Remove trailing comma from the options line that preceded the Tag
        sed -i 's/\.set_exclusive_locking(false),/.set_exclusive_locking(false)/' "${db_file}"
        echo "  OK   removed sql::Database::Tag from $(basename "${db_file}")"
        APPLIED=$((APPLIED + 1))
    else
        echo "  SKIP  sql::Database::Tag already fixed in $(basename "${db_file}")"
        SKIPPED=$((SKIPPED + 1))
    fi
done
# Also undo any prior damage to sql/database.h from earlier repair attempts
SQL_DB_H="${SRC_DIR}/sql/database.h"
if [ -f "${SQL_DB_H}" ] && grep -q "tag\[0\] == 'A'" "${SQL_DB_H}" 2>/dev/null; then
    echo "  Reverting prior ABP tag patch from sql/database.h..."
    sed -i "/tag\[0\] == 'A' && tag\[1\] == 'B'/d" "${SQL_DB_H}"
fi

# ---------------------------------------------------------------------------
# Fix 2: ui::mojom::CursorType incomplete type in abp_controller.h
#
# The header uses ui::mojom::CursorType::kPointer but only has a forward
# declaration (or a transitive include that no longer provides the full def).
# We ensure the full mojom-shared header is included.
# ---------------------------------------------------------------------------
CONTROLLER_H="${ABP_DIR}/abp_controller.h"
if [ -f "${CONTROLLER_H}" ]; then
    if grep -q 'cursor_type.mojom-shared.h\|cursor_type.mojom.h' "${CONTROLLER_H}"; then
        echo "  SKIP  CursorType full include already present in abp_controller.h"
        SKIPPED=$((SKIPPED + 1))
    else
        python3 - "${CONTROLLER_H}" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

new_include = '#include "ui/base/cursor/mojom/cursor_type.mojom-shared.h"  // ABP compat'

# If there's a forward-only include, replace it.
if 'cursor_type.mojom-forward.h' in content:
    content = content.replace(
        'cursor_type.mojom-forward.h',
        'cursor_type.mojom-shared.h"  // ABP compat\n// was: cursor_type.mojom-forward.h (replaced for full enum def')
    # Actually let's do a cleaner replace
    # Re-read
    with open(filepath, 'r') as f:
        content = f.read()
    content = content.replace(
        '#include "ui/base/cursor/mojom/cursor_type.mojom-forward.h"',
        new_include)
else:
    # No cursor include at all — add after the last #include
    last_inc = content.rfind('#include ')
    if last_inc >= 0:
        eol = content.find('\n', last_inc)
        content = content[:eol + 1] + new_include + '\n' + content[eol + 1:]
    else:
        print("  WARN  no #include found in abp_controller.h")
        sys.exit(0)

with open(filepath, 'w') as f:
    f.write(content)
print("  OK   added CursorType full include to abp_controller.h")
PYEOF
        APPLIED=$((APPLIED + 1))
    fi
else
    echo "  SKIP  abp_controller.h not found"
    SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------------------
# Fix 3: Missing vector icon resources (kAbpHumanIcon, kAbpCdpIcon, kAbpRobotIcon)
#
# These icons are referenced in abp_input_mode_icon_view.cc but not defined
# anywhere in the build.  We inject stub VectorIcon constants after the
# #include block.  ABP runs headless so these icons are never rendered.
# ---------------------------------------------------------------------------
ICON_VIEW="${ABP_DIR}/abp_input_mode_icon_view.cc"
if [ -f "${ICON_VIEW}" ]; then
    if grep -q 'ABP compat: stub icons' "${ICON_VIEW}"; then
        echo "  SKIP  icon stubs already present in abp_input_mode_icon_view.cc"
        SKIPPED=$((SKIPPED + 1))
    else
        python3 - "${ICON_VIEW}" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Ensure the vector_icon_types header is included.
if 'vector_icon_types.h' not in content:
    first_include = content.find('#include')
    if first_include >= 0:
        eol = content.find('\n', first_include)
        content = (content[:eol + 1]
                   + '#include "ui/gfx/vector_icon_types.h"  // ABP compat\n'
                   + content[eol + 1:])

# Find the end of the #include block: the first line after all
# consecutive #include / comment / blank lines.
lines = content.split('\n')
insert_idx = 0
in_includes = False
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith('#include') or stripped.startswith('#if') or stripped.startswith('#endif') or stripped.startswith('#define') or stripped.startswith('#ifndef') or stripped.startswith('#pragma'):
        in_includes = True
        insert_idx = i + 1
    elif in_includes and (stripped == '' or stripped.startswith('//')):
        insert_idx = i + 1
    elif in_includes:
        break

stub = [
    '',
    '// ABP compat: stub icons for headless mode (originals not in this build).',
    'namespace {',
    'const gfx::VectorIcon kAbpHumanIcon{};',
    'const gfx::VectorIcon kAbpCdpIcon{};',
    'const gfx::VectorIcon kAbpRobotIcon{};',
    '}  // namespace',
    '',
]

for j, s in enumerate(stub):
    lines.insert(insert_idx + j, s)

content = '\n'.join(lines)

with open(filepath, 'w') as f:
    f.write(content)
print("  OK   stubbed icon resources in abp_input_mode_icon_view.cc")
PYEOF
        APPLIED=$((APPLIED + 1))
    fi
else
    echo "  SKIP  abp_input_mode_icon_view.cc not found"
    SKIPPED=$((SKIPPED + 1))
fi

echo "==> ABP compat edits complete. Applied: ${APPLIED}, Skipped: ${SKIPPED}"
