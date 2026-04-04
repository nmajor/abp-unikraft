#!/bin/bash
# Ensure Chromium's Rust toolchain (CIPD) is present in a tarball-based checkout.
# Usage: ./scripts/ensure-rust-toolchain.sh /path/to/chromium/src
set -euo pipefail

SRC_DIR="${1:?usage: $0 /path/to/chromium/src}"
TOOL_DIR="/root/depot_tools"
DEST_DIR="${SRC_DIR}/third_party/rust-toolchain"

if [ -f "${DEST_DIR}/VERSION" ] && [ -x "${DEST_DIR}/bin/rustc" ]; then
  echo "  Rust toolchain already present at ${DEST_DIR}."
  exit 0
fi

# Install depot_tools for cipd if missing.
if [ ! -d "${TOOL_DIR}" ]; then
  echo "  Installing depot_tools for CIPD..."
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "${TOOL_DIR}"
fi
export PATH="${TOOL_DIR}:${PATH}"

# Determine CIPD package version from DEPS, fallback to latest.
DEPS_FILE="${SRC_DIR}/DEPS"
CIPD_VERSION=""
if [ -f "${DEPS_FILE}" ]; then
  CIPD_VERSION="$(python3 - <<'PY' "${DEPS_FILE}" 2>/dev/null || true)
import re, sys
text=open(sys.argv[1], 'r', encoding='utf-8', errors='ignore').read()
# Try to capture an explicit version entry near the rust-toolchain cipd stanza.
m=re.search(r"chromium/third_party/rust-toolchain[^']*'.*?\n\s*'version'\s*:\s*'([^']+)'", text, re.S)
if not m:
    # Sometimes the version is in vars like 'rust_toolchain_version'. Resolve simple string cases.
    mvar=re.search(r"'rust_toolchain_version'\s*:\s*'([^']+)'", text)
    if mvar:
        print(mvar.group(1)); sys.exit(0)
    # Fallback: capture any 'version:' style tag.
    mver=re.search(r"version:\s*([A-Za-z0-9_\.\-]+)", text)
    if mver:
        print(mver.group(0))
        sys.exit(0)
    print("")
else:
    print(m.group(1))
PY
)"
fi

mkdir -p "${DEST_DIR}"
platform_pkg="chromium/third_party/rust-toolchain/linux-amd64"
candidates=(
  "${platform_pkg}"
  "chromium/third_party/rust/linux-amd64"
  "chromium/third_party/rust-toolchain"
  "chromium/third_party/rust"
)

for pkg in "${candidates[@]}"; do
  echo "  Attempting CIPD install: ${pkg} ${CIPD_VERSION:-latest}"
  if cipd install "${pkg}" "${CIPD_VERSION:-latest}" -root "${DEST_DIR}" >/dev/null 2>&1; then
    if [ -x "${DEST_DIR}/bin/rustc" ] && [ -f "${DEST_DIR}/VERSION" ]; then
      echo "  Installed Rust toolchain from ${pkg} (${CIPD_VERSION:-latest})."
      exit 0
    fi
  fi
done

# As a last resort, try system Rust so GN can proceed; may still fail at build time.
echo "  CIPD install failed; installing system rustc/cargo as fallback..."
apt-get update && apt-get install -y --no-install-recommends rustc cargo || true
if command -v rustc >/dev/null 2>&1; then
  mkdir -p "${DEST_DIR}/bin"
  ln -sf "$(command -v rustc)" "${DEST_DIR}/bin/rustc" || true
  echo "system-rust" > "${DEST_DIR}/VERSION"
  echo "  Using system rustc at $(command -v rustc)."
  exit 0
fi

echo "ERROR: Unable to provision Rust toolchain for Chromium (CIPD + system fallback failed)." >&2
exit 1
