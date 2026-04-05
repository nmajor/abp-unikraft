#!/bin/bash
# Deterministic preflight checks for the fp-chromium + ABP build pipeline.
#
# Modes:
#   repo <repo-dir>
#     Cheap local checks against this repo before provisioning Hetzner work.
#   src <chromium-src-dir> [repo-dir]
#     Source-tree checks after overlay/toolchain/bootstrap work on the VM.
#
# Optional env:
#   PRECHECK_NINJA_TARGETS="chrome chromedriver"   # defaults to these targets
#   PRECHECK_COMPILE_TARGETS="..."                 # optional targeted probes
#   PRECHECK_NINJA_JOBS="8"                        # jobs for optional probes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_DIR="$(dirname "${SCRIPT_DIR}")"

usage() {
    cat <<EOF
Usage:
  $0 repo [repo-dir]
  $0 src <chromium-src-dir> [repo-dir]
EOF
}

log() {
    printf '==> %s\n' "$*"
}

ok() {
    printf '  OK   %s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_file() {
    local path="$1"
    [ -f "${path}" ] || fail "required file missing: ${path}"
}

require_exec() {
    local path="$1"
    [ -x "${path}" ] || fail "required executable missing: ${path}"
}

assert_file_contains() {
    local path="$1"
    local pattern="$2"
    local label="$3"
    if ! grep -Eq "${pattern}" "${path}"; then
        fail "${label} not found in ${path}"
    fi
    ok "${label}"
}

check_shell_syntax() {
    local path="$1"
    bash -n "${path}"
    ok "shell syntax ${path}"
}

check_python_syntax() {
    local path="$1"
    python3 -m py_compile "${path}"
    ok "python syntax ${path}"
}

run_repo_preflight() {
    local repo_dir="${1:-${DEFAULT_REPO_DIR}}"

    log "Running repo preflight in ${repo_dir}"

    local shell_scripts=(
        "${repo_dir}/scripts/build-on-fp-chromium.sh"
        "${repo_dir}/scripts/hetzner-build.sh"
        "${repo_dir}/scripts/watchdog-hetzner.sh"
        "${repo_dir}/scripts/watchdog-remote.sh"
        "${repo_dir}/scripts/ensure-rust-toolchain.sh"
        "${repo_dir}/scripts/ensure-node-esbuild.sh"
        "${repo_dir}/scripts/preflight-fp-chromium-build.sh"
        "${repo_dir}/scripts/verify-abp-overlay-contract.sh"
        "${repo_dir}/scripts/apply-stealth-extra-edits.sh"
        "${repo_dir}/scripts/apply-feature-edits.sh"
        "${repo_dir}/wrapper.sh"
    )

    local script
    for script in "${shell_scripts[@]}"; do
        require_file "${script}"
        check_shell_syntax "${script}"
    done

    if [ -f "${repo_dir}/scripts/patch_flags_state.py" ]; then
        check_python_syntax "${repo_dir}/scripts/patch_flags_state.py"
    fi

    ok "repo preflight passed"
}

run_src_preflight() {
    local src_dir="${1:?chromium src dir required}"
    local repo_dir="${2:-${DEFAULT_REPO_DIR}}"
    local release_dir="${src_dir}/out/Release"
    local ninja_targets="${PRECHECK_NINJA_TARGETS:-chrome chromedriver}"

    log "Running source preflight in ${src_dir}"

    require_file "${repo_dir}/scripts/verify-abp-overlay-contract.sh"
    require_exec "${src_dir}/out/Release/gn"
    require_exec "${src_dir}/third_party/rust-toolchain/bin/rustc"
    require_exec "${src_dir}/third_party/node/linux/node-linux-x64/bin/node"
    require_exec "${src_dir}/third_party/devtools-frontend/src/third_party/esbuild/esbuild"
    require_file "${release_dir}/args.gn"

    bash "${repo_dir}/scripts/verify-abp-overlay-contract.sh" "${src_dir}"

    assert_file_contains "${release_dir}/args.gn" 'use_sysroot *= *false' "args.gn sets use_sysroot=false"
    assert_file_contains "${release_dir}/args.gn" 'use_cups *= *false' "args.gn sets use_cups=false"
    assert_file_contains "${release_dir}/args.gn" 'use_vaapi *= *false' "args.gn sets use_vaapi=false"

    (
        cd "${src_dir}"
        ./out/Release/gn gen "${release_dir}" --fail-on-unused-args
    )
    ok "gn gen"

    ninja -C "${release_dir}" -n ${ninja_targets}
    ok "ninja dry-run ${ninja_targets}"

    if [ -n "${PRECHECK_COMPILE_TARGETS:-}" ]; then
        local jobs="${PRECHECK_NINJA_JOBS:-$(nproc 2>/dev/null || echo 4)}"
        ninja -C "${release_dir}" -j "${jobs}" ${PRECHECK_COMPILE_TARGETS}
        ok "targeted compile probes ${PRECHECK_COMPILE_TARGETS}"
    fi

    ok "source preflight passed"
}

mode="${1:-}"
case "${mode}" in
    repo)
        run_repo_preflight "${2:-${DEFAULT_REPO_DIR}}"
        ;;
    src)
        [ $# -ge 2 ] || { usage; exit 1; }
        run_src_preflight "$2" "${3:-${DEFAULT_REPO_DIR}}"
        ;;
    *)
        usage
        exit 1
        ;;
esac
