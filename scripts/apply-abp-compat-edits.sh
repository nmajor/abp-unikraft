#!/bin/bash
# Apply compatibility edits to ABP protocol source for Chromium 142.
#
# ABP was developed against an older Chromium version. These edits fix
# API changes in Chromium 142 that break compilation:
#
# 1. sql::Database::Tag is now consteval — use static constexpr tag
# 2. ui::mojom::CursorType needs full header, not just forward decl
# 3. kAbpHumanIcon etc. are missing — stub them out
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
# Fix 1: sql::Database::Tag consteval issue
# In Chromium 142, sql::Database::Tag("ABP") must be a compile-time constant.
# Replace the runtime Tag construction with a static constexpr variable.
# ---------------------------------------------------------------------------
for db_file in "${ABP_DIR}/abp_network_database.cc" "${ABP_DIR}/abp_history_database.cc"; do
    if [ ! -f "${db_file}" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if grep -q 'sql::Database::Tag("ABP")' "${db_file}"; then
        # In Chromium 142, Tag's constructor is consteval so it can only be
        # called in a constant expression context. Hoist it to a static
        # constexpr variable and reference that instead.
        sed -i '/sql::Database::Tag("ABP")/i\  static constexpr auto kAbpDbTag = sql::Database::Tag("ABP");' "${db_file}"
        sed -i 's/sql::Database::Tag("ABP")/kAbpDbTag/g' "${db_file}"
        echo "  OK   fixed sql::Database::Tag in $(basename "${db_file}")"
        APPLIED=$((APPLIED + 1))
    else
        echo "  SKIP  sql::Database::Tag already fixed in $(basename "${db_file}")"
        SKIPPED=$((SKIPPED + 1))
    fi
done

# ---------------------------------------------------------------------------
# Fix 2: ui::mojom::CursorType incomplete type
# The forward declaration header doesn't provide enum values. Replace with
# the full header.
# ---------------------------------------------------------------------------
CONTROLLER_H="${ABP_DIR}/abp_controller.h"
if [ -f "${CONTROLLER_H}" ]; then
    if grep -q 'cursor_type.mojom-forward.h' "${CONTROLLER_H}"; then
        sed -i 's|ui/base/cursor/mojom/cursor_type.mojom-forward.h|ui/base/cursor/mojom/cursor_type.mojom.h|' "${CONTROLLER_H}"
        echo "  OK   fixed CursorType include in abp_controller.h"
        APPLIED=$((APPLIED + 1))
    else
        echo "  SKIP  CursorType include already fixed in abp_controller.h"
        SKIPPED=$((SKIPPED + 1))
    fi
fi

# ---------------------------------------------------------------------------
# Fix 3: Missing icon resources (kAbpHumanIcon, kAbpCdpIcon, kAbpRobotIcon)
# These vector icons may not exist in the current build. Stub them with
# empty vector icons to unblock compilation.
# ---------------------------------------------------------------------------
ICON_VIEW="${ABP_DIR}/abp_input_mode_icon_view.cc"
if [ -f "${ICON_VIEW}" ]; then
    if grep -q 'kAbpHumanIcon\|kAbpCdpIcon\|kAbpRobotIcon' "${ICON_VIEW}"; then
        # Add stub icon definitions after the existing includes
        sed -i '/^#include/,/^[^#]/{
            /^[^#]/{
                i\
// Stub ABP icons for Chromium 142 compat (original icons not in build).\
namespace {\
const gfx::VectorIcon kAbpHumanIcon;\
const gfx::VectorIcon kAbpCdpIcon;\
const gfx::VectorIcon kAbpRobotIcon;\
}  // namespace
                b done
            }
        }
        :done' "${ICON_VIEW}"
        # Also ensure the vector icon header is included
        if ! grep -q 'ui/gfx/vector_icon_types.h' "${ICON_VIEW}"; then
            sed -i '1i #include "ui/gfx/vector_icon_types.h"' "${ICON_VIEW}"
        fi
        echo "  OK   stubbed icon resources in abp_input_mode_icon_view.cc"
        APPLIED=$((APPLIED + 1))
    else
        echo "  SKIP  icon resources already fixed in abp_input_mode_icon_view.cc"
        SKIPPED=$((SKIPPED + 1))
    fi
fi

echo "==> ABP compat edits complete. Applied: ${APPLIED}, Skipped: ${SKIPPED}"
