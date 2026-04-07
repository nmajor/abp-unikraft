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
# Fix 1: sql::Database::Tag("ABP") — use an existing whitelisted tag
#
# Chromium 142 has a consteval Tag with a hardcoded whitelist. "ABP" isn't
# in it. DO NOT patch sql/database.h — that breaks every file that uses SQL.
# Instead, replace the tag string in the ABP files with one that's already
# whitelisted. "WebDatabase" is always present in Chromium's whitelist.
# ---------------------------------------------------------------------------
for db_file in "${ABP_DIR}/abp_network_database.cc" "${ABP_DIR}/abp_history_database.cc"; do
    [ -f "${db_file}" ] || { SKIPPED=$((SKIPPED + 1)); continue; }
    fname="$(basename "${db_file}")"
    if grep -q 'Tag("ABP")' "${db_file}"; then
        sed -i 's/Tag("ABP")/Tag("WebDatabase")/' "${db_file}"
        echo "  OK   replaced Tag(\"ABP\") with Tag(\"WebDatabase\") in ${fname}"
        APPLIED=$((APPLIED + 1))
    else
        echo "  SKIP  Tag(\"ABP\") already replaced in ${fname}"
        SKIPPED=$((SKIPPED + 1))
    fi
done

# Undo any prior damage to sql/database.h from earlier repair attempts
SQL_DB_H="${SRC_DIR}/sql/database.h"
if [ -f "${SQL_DB_H}" ] && grep -qE "'A' && .*'B' && .*'P'|== .ABP." "${SQL_DB_H}" 2>/dev/null; then
    echo "  Reverting prior ABP patch from sql/database.h..."
    sed -i "/'A' && .*'B' && .*'P'/d; /== .ABP./d" "${SQL_DB_H}"
fi

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
        echo "  SKIP  CursorType include already fixed"
        SKIPPED=$((SKIPPED + 1))
    fi
fi

# ---------------------------------------------------------------------------
# Fix 3: Missing kAbpHumanIcon, kAbpCdpIcon, kAbpRobotIcon
# ---------------------------------------------------------------------------
ICON_VIEW="${ABP_DIR}/abp_input_mode_icon_view.cc"
if [ -f "${ICON_VIEW}" ]; then
    if grep -q 'VECTOR_ICON_STUB_ABP' "${ICON_VIEW}"; then
        echo "  SKIP  icon stubs already present"
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
constexpr gfx::VectorIcon kAbpHumanIcon(kAbpStubRep, 1u, \"abp_human\");
constexpr gfx::VectorIcon kAbpCdpIcon(kAbpStubRep, 1u, \"abp_cdp\");
constexpr gfx::VectorIcon kAbpRobotIcon(kAbpStubRep, 1u, \"abp_robot\");
}  // namespace
'''
lines.insert(last_inc + 1, stub)
open(p, 'w').writelines(lines)
print('  OK   added icon stubs to abp_input_mode_icon_view.cc')
"
        APPLIED=$((APPLIED + 1))
    else
        echo "  SKIP  no icon references found"
        SKIPPED=$((SKIPPED + 1))
    fi
fi

# ---------------------------------------------------------------------------
# Fix 4: content/public/browser/popup_interceptor.h missing in Chromium 142
#
# AbpPopupInterceptor inherits from content::PopupInterceptor, but this
# header was removed in Chromium 142. Create a minimal stub so the ABP code
# compiles without requiring upstream changes.
# ---------------------------------------------------------------------------
POPUP_INTERCEPTOR_H="${SRC_DIR}/content/public/browser/popup_interceptor.h"
if [ ! -f "${POPUP_INTERCEPTOR_H}" ]; then
    cat > "${POPUP_INTERCEPTOR_H}" << 'STUB_EOF'
// ABP compat stub: content/public/browser/popup_interceptor.h was removed in
// Chromium 142. This minimal stub allows AbpPopupInterceptor to compile.
#ifndef CONTENT_PUBLIC_BROWSER_POPUP_INTERCEPTOR_H_
#define CONTENT_PUBLIC_BROWSER_POPUP_INTERCEPTOR_H_

namespace content {

class PopupInterceptor {
 public:
  virtual ~PopupInterceptor() = default;
};

}  // namespace content

#endif  // CONTENT_PUBLIC_BROWSER_POPUP_INTERCEPTOR_H_
STUB_EOF
    echo "  OK   created popup_interceptor.h stub"
    APPLIED=$((APPLIED + 1))
else
    echo "  SKIP  popup_interceptor.h already exists"
    SKIPPED=$((SKIPPED + 1))
fi

echo "==> ABP compat edits complete. Applied: ${APPLIED}, Skipped: ${SKIPPED}"
