#!/bin/bash
# Ensure Node.js and esbuild binaries are available in a tarball-based
# Chromium checkout (no gclient/cipd). This mirrors what runhooks would
# normally provision.
#
# Usage: ./scripts/ensure-node-esbuild.sh /path/to/chromium/src
set -euo pipefail

SRC_DIR="${1:?usage: $0 /path/to/chromium/src}"

log() { printf '  %s\n' "$*"; }

ensure_node() {
  local node_dir="${SRC_DIR}/third_party/node/linux/node-linux-x64/bin"
  local node_bin="${node_dir}/node"

  # Discover expected Node version from the source tree.
  local expected=""
  if [ -d "${SRC_DIR}/third_party/node" ]; then
    # Try explicit 'Expected version vX.Y.Z' marker first.
    expected="$(grep -R -nE 'Expected version[^v]*v[0-9]+\.[0-9]+\.[0-9]+' "${SRC_DIR}/third_party/node" 2>/dev/null | \
      sed -E 's/.*(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -n1)"
    if [ -z "${expected}" ]; then
      # Fallback to NODE_VERSION or node_version assignments.
      expected="$(grep -R -nE '(NODE_VERSION|node_version)[^0-9]*([0-9]+\.[0-9]+\.[0-9]+)' "${SRC_DIR}/third_party/node" 2>/dev/null | \
        sed -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' | head -n1)"
    fi
  fi
  if [ -z "${expected}" ]; then
    # Conservative default known-good for Chromium 142 era.
    expected="v22.11.0"
  fi

  # Normalize to leading 'v'.
  case "${expected}" in
    v*) ;;
    *) expected="v${expected}" ;;
  esac

  # If node exists and matches expected, keep it.
  if [ -x "${node_bin}" ]; then
    set +e
    have_version="$(${node_bin} --version 2>/dev/null | tr -d '\r' || true)"
    set -e
    if [ "${have_version}" = "${expected}" ]; then
      log "Node already present (${have_version})"
      return 0
    fi
    log "Replacing Node ${have_version:-unknown} → ${expected}"
  else
    log "Installing Node ${expected}"
  fi

  local tarball="/tmp/node-v${expected#v}-linux-x64.tar.xz"
  local extract="/tmp/node-v${expected#v}-linux-x64"
  mkdir -p "${node_dir}"
  rm -rf "${extract}" 2>/dev/null || true

  if command -v wget >/dev/null 2>&1; then
    wget -q "https://nodejs.org/dist/${expected}/node-v${expected#v}-linux-x64.tar.xz" -O "${tarball}"
  else
    curl -fsSL -o "${tarball}" "https://nodejs.org/dist/${expected}/node-v${expected#v}-linux-x64.tar.xz"
  fi
  tar -xJf "${tarball}" -C /tmp/
  cp "${extract}/bin/node" "${node_bin}"
  chmod +x "${node_bin}"
}

ensure_esbuild() {
  # DevTools expects a vendored esbuild binary at this path when not using CIPD.
  local es_dir="${SRC_DIR}/third_party/devtools-frontend/src/third_party/esbuild"
  local es_bin="${es_dir}/esbuild"

  # If already present and executable, do nothing.
  if [ -x "${es_bin}" ]; then
    log "esbuild already present"
    return 0
  fi

  # Try to read the version from DevTools package.json; fallback to a
  # known-good for Chromium ~142.x.
  local pkg_json="${SRC_DIR}/third_party/devtools-frontend/src/package.json"
  local ver=""
  if [ -f "${pkg_json}" ]; then
    ver="$(python3 - "$pkg_json" 2>/dev/null <<'PY' || true
import json, re, sys
try:
    j=json.load(open(sys.argv[1]))
    # Prefer exact pin; devDependencies tends to carry esbuild.
    for key in ("dependencies","devDependencies"):
        d=j.get(key,{})
        if "esbuild" in d:
            v=d["esbuild"]
            # strip leading ^ or ~ if present
            print(re.sub(r'^[\^~]', '', v))
            raise SystemExit
except Exception:
    pass
print("")
PY
    )"
  fi
  if [ -z "${ver}" ]; then
    ver="0.25.1"
  fi

  log "Installing esbuild ${ver}"
  mkdir -p "${es_dir}"
  local tgz="/tmp/esbuild-${ver}.tgz"
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "${tgz}" "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-${ver}.tgz"
  else
    curl -fsSL -o "${tgz}" "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-${ver}.tgz"
  fi
  local tmpdir
  tmpdir="$(mktemp -d)"
  tar -xzf "${tgz}" -C "${tmpdir}"
  cp "${tmpdir}/package/bin/esbuild" "${es_bin}"
  chmod +x "${es_bin}"
  rm -rf "${tmpdir}"
}

ensure_node
ensure_esbuild
log "Tooling ensured (node + esbuild)."
