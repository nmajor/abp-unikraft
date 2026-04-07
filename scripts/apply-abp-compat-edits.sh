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
# Fix 1: sql::Database::Tag("ABP") — remove Tag arg from constructor
#
# Chromium 142 made Tag consteval with a hardcoded whitelist that doesn't
# include "ABP". The simplest fix: use the 1-arg Database(Options) overload.
#
# Before:
#   db_ = std::make_unique<sql::Database>(
#       sql::DatabaseOptions()
#           .set_wal_mode(true)
#           .set_exclusive_locking(false),
#       sql::Database::Tag("ABP"));
#
# After:
#   db_ = std::make_unique<sql::Database>(
#       sql::DatabaseOptions()
#           .set_wal_mode(true)
#           .set_exclusive_locking(false));
# ---------------------------------------------------------------------------
for db_file in "${ABP_DIR}/abp_network_database.cc" "${ABP_DIR}/abp_history_database.cc"; do
    if [ ! -f "${db_file}" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    fname="$(basename "${db_file}")"
    if grep -q 'sql::Database::Tag(' "${db_file}"; then
        # Replace the exact 2-line pattern: trailing comma + Tag line
        sed -i 'N;s/\.set_exclusive_locking(false),\n[[:space:]]*sql::Database::Tag("ABP"));/.set_exclusive_locking(false));/' "${db_file}"
        if grep -q 'sql::Database::Tag(' "${db_file}"; then
            echo "  WARN  sed pattern did not match in ${fname}, trying Python..."
            python3 -c "
import sys
p = '${db_file}'
t = open(p).read()
t = t.replace('.set_exclusive_locking(false),\n      sql::Database::Tag(\"ABP\"));', '.set_exclusive_locking(false));')
open(p,'w').write(t)
"
        fi
        if grep -q 'sql::Database::Tag(' "${db_file}"; then
            echo "  FAIL  could not remove Tag from ${fname}"
        else
            echo "  OK   removed sql::Database::Tag from ${fname}"
            APPLIED=$((APPLIED + 1))
        fi
    else
        echo "  SKIP  sql::Database::Tag already fixed in ${fname}"
        SKIPPED=$((SKIPPED + 1))
    fi
done

# Undo any prior damage to sql/database.h from earlier repair attempts
SQL_DB_H="${SRC_DIR}/sql/database.h"
if [ -f "${SQL_DB_H}" ] && grep -q "tag\[0\] == 'A'" "${SQL_DB_H}" 2>/dev/null; then
    echo "  Reverting prior ABP tag patch from sql/database.h..."
    sed -i "/tag\[0\] == 'A' && tag\[1\] == 'B'/d" "${SQL_DB_H}"
fi

# ---------------------------------------------------------------------------
# Fix 2: ui::mojom::CursorType incomplete type in abp_controller.h
#
# Replace forward-declaration header with full enum definition header.
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
#
# These icons are referenced but not defined anywhere. The file includes
# chrome/app/vector_icons/vector_icons.h but ABP's icons aren't registered
# there. We define empty VectorIcon stubs after the includes.
# ---------------------------------------------------------------------------
ICON_VIEW="${ABP_DIR}/abp_input_mode_icon_view.cc"
if [ -f "${ICON_VIEW}" ]; then
    if grep -q 'VECTOR_ICON_STUB_ABP' "${ICON_VIEW}"; then
        echo "  SKIP  icon stubs already present in abp_input_mode_icon_view.cc"
        SKIPPED=$((SKIPPED + 1))
    elif grep -q 'kAbpHumanIcon' "${ICON_VIEW}"; then
        # Insert stub definitions after the last #include line
        python3 -c "
import sys
p = '${ICON_VIEW}'
lines = open(p).readlines()
# Find last #include line
last_inc = 0
for i, l in enumerate(lines):
    if l.strip().startswith('#include'):
        last_inc = i
# Insert after last include
stub = '''
// VECTOR_ICON_STUB_ABP — Chromium 142 compat: ABP icons not in vector_icons.h
#include \"ui/gfx/vector_icon_types.h\"
namespace {
// Stub icons — ABP runs headless, icons never rendered.
// PathElement is now a 1-arg union ({command} not {command,x,y,r}).
// VectorIconRep/VectorIcon take spans — no explicit count arg.
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
