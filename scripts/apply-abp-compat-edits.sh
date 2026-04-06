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
# Fix 1: Register "ABP" in sql::Database::Tag whitelist (sql/database.h)
#
# In Chromium 142, sql::Database::Tag is consteval and validates against a
# hardcoded list of known tags.  Unrecognised tags hit NOTREACHED() which
# is not constexpr, so compilation fails.  We insert a character-by-character
# check for "ABP" just before the NOTREACHED line.
# ---------------------------------------------------------------------------
SQL_DB_H="${SRC_DIR}/sql/database.h"
if [ -f "${SQL_DB_H}" ]; then
    if grep -q '"ABP"' "${SQL_DB_H}" || grep -q "'A' && tag\[1\] == 'B'" "${SQL_DB_H}"; then
        echo "  SKIP  ABP tag already registered in sql/database.h"
        SKIPPED=$((SKIPPED + 1))
    else
        python3 - "${SQL_DB_H}" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Find the NOTREACHED inside the Tag constructor.
# The diagnostic "Invalid database tag" is on or near the NOTREACHED line.
diag_idx = content.find('Invalid database tag')
if diag_idx < 0:
    print("  WARN  'Invalid database tag' not found in sql/database.h")
    sys.exit(0)

# Walk backwards to find the start of the NOTREACHED line.
notreached_line_start = content.rfind('\n', 0, diag_idx) + 1

# Grab indentation from the NOTREACHED line.
rest = content[notreached_line_start:]
indent = ''
for ch in rest:
    if ch in (' ', '\t'):
        indent += ch
    else:
        break
if not indent:
    indent = '        '

# Insert a constexpr-safe character comparison for "ABP" just before NOTREACHED.
# We use character-by-character comparison because consteval context
# cannot call strcmp/memcmp.
check = (f'{indent}if (tag[0] == \'A\' && tag[1] == \'B\' && '
         f'tag[2] == \'P\' && tag[3] == \'\\0\') return;\n')

content = content[:notreached_line_start] + check + content[notreached_line_start:]

with open(filepath, 'w') as f:
    f.write(content)
print("  OK   registered ABP tag in sql/database.h")
PYEOF
        APPLIED=$((APPLIED + 1))
    fi
else
    echo "  SKIP  sql/database.h not found"
    SKIPPED=$((SKIPPED + 1))
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
