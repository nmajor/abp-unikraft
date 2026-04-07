#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.cache/abp-watchdog}"
STATE_FILE="${STATE_DIR}/state.env"
PROMPT_FILE="${STATE_DIR}/prompt.md"
AUDIT_LOG_FILE="${STATE_DIR}/audit.log"
CRON_LOG_FILE="${STATE_DIR}/cron.log"
LOG_FILE="${STATE_DIR}/watchdog.log"
CHECKS_DIR="${STATE_DIR}/checks"
LOCK_DIR="${STATE_DIR}/lock"
LOCK_META_FILE="${LOCK_DIR}/meta.env"

HETZNER_API="${HETZNER_API_TOKEN:-}"
GH_TOKEN="${GH_TOKEN:-}"
WATCHDOG_CLAUDE_BIN="${WATCHDOG_CLAUDE_BIN:-/var/lib/asdf/installs/nodejs/24.8.0/bin/claude}"
WATCHDOG_CLAUDE_TIMEOUT_SECONDS="${WATCHDOG_CLAUDE_TIMEOUT_SECONDS:-600}"
WATCHDOG_RUN_CLAUDE="${WATCHDOG_RUN_CLAUDE:-1}"
WATCHDOG_CLAUDE_REPAIR_MODEL="${WATCHDOG_CLAUDE_REPAIR_MODEL:-sonnet}"

# Guardrails
WATCHDOG_MAX_REPAIRS="${WATCHDOG_MAX_REPAIRS:-10}"
WATCHDOG_MAX_SAME_FAILURE="${WATCHDOG_MAX_SAME_FAILURE:-5}"

# Post-build automation
WATCHDOG_AUTO_DEPLOY="${WATCHDOG_AUTO_DEPLOY:-1}"
WATCHDOG_AUTO_SMOKE_TEST="${WATCHDOG_AUTO_SMOKE_TEST:-1}"
WATCHDOG_DEPLOY_TIMEOUT_SECONDS="${WATCHDOG_DEPLOY_TIMEOUT_SECONDS:-600}"
WATCHDOG_KRAFT_TOKEN="${WATCHDOG_KRAFT_TOKEN:-}"

WATCHDOG_SERVER_TYPE="${WATCHDOG_SERVER_TYPE:-cpx51}"
WATCHDOG_SERVER_LOCATION="${WATCHDOG_SERVER_LOCATION:-hil}"
WATCHDOG_SERVER_IMAGE="${WATCHDOG_SERVER_IMAGE:-ubuntu-22.04}"
WATCHDOG_SERVER_NAME_PREFIX="${WATCHDOG_SERVER_NAME_PREFIX:-abp-watchdog}"
WATCHDOG_SSH_KEY_NAME="${WATCHDOG_SSH_KEY_NAME:-abp-build-key}"
WATCHDOG_REPO_URL="${WATCHDOG_REPO_URL:-https://github.com/nmajor/abp-unikraft.git}"
WATCHDOG_REPO_REF="${WATCHDOG_REPO_REF:-main}"
WATCHDOG_FP_CHROMIUM_TAG="${WATCHDOG_FP_CHROMIUM_TAG:-142.0.7444.175}"
WATCHDOG_ABP_BRANCH="${WATCHDOG_ABP_BRANCH:-dev}"
WATCHDOG_FLOW_TIMEOUT_HOURS="${WATCHDOG_FLOW_TIMEOUT_HOURS:-24}"
WATCHDOG_LOCK_WARN_MINUTES="${WATCHDOG_LOCK_WARN_MINUTES:-60}"
WATCHDOG_LOCK_WARN_SKIPS="${WATCHDOG_LOCK_WARN_SKIPS:-12}"
WATCHDOG_SSH_TIMEOUT="${WATCHDOG_SSH_TIMEOUT:-10}"

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout="${WATCHDOG_SSH_TIMEOUT}"
    -o LogLevel=ERROR
)

usage() {
    cat <<EOF
Usage: $0 [cycle|status|prompt|cleanup|install-cron|uninstall-cron]

State dir: ${STATE_DIR}
Server type: ${WATCHDOG_SERVER_TYPE}
fp-chromium tag: ${WATCHDOG_FP_CHROMIUM_TAG}
Flow timeout hours: ${WATCHDOG_FLOW_TIMEOUT_HOURS}
EOF
}

log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

audit_log() {
    ensure_state_dir
    printf '[%s] phase=%s status=%s flow=%s server=%s ip=%s repair=%s release=%s :: %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${WATCHDOG_PHASE:-}" \
        "${WATCHDOG_LAST_STATUS:-}" \
        "${WATCHDOG_FLOW_ID:-}" \
        "${WATCHDOG_SERVER_NAME:-}" \
        "${WATCHDOG_SERVER_IP:-}" \
        "${WATCHDOG_REPAIR_COUNT:-0}" \
        "${WATCHDOG_RELEASE_TAG:-}" \
        "$*" >> "${AUDIT_LOG_FILE}"
}

ensure_state_dir() {
    mkdir -p "${STATE_DIR}" "${CHECKS_DIR}"
}

shell_escape() {
    printf '%q' "${1:-}"
}

state_load() {
    if [ -f "${STATE_FILE}" ]; then
        local rc
        set +e
        # shellcheck disable=SC1090
        . "${STATE_FILE}"
        rc=$?
        set -e
        if [ "${rc}" -ne 0 ]; then
            WATCHDOG_LAST_STATUS="watchdog state file is corrupt"
            return 0
        fi
    fi
    return 0
}

state_write() {
    cat > "${STATE_FILE}" <<EOF
WATCHDOG_FLOW_ID=$(shell_escape "${WATCHDOG_FLOW_ID:-}")
WATCHDOG_PHASE=$(shell_escape "${WATCHDOG_PHASE:-idle}")
WATCHDOG_SERVER_ID=$(shell_escape "${WATCHDOG_SERVER_ID:-}")
WATCHDOG_SERVER_IP=$(shell_escape "${WATCHDOG_SERVER_IP:-}")
WATCHDOG_SERVER_NAME=$(shell_escape "${WATCHDOG_SERVER_NAME:-}")
WATCHDOG_REPO_SHA=$(shell_escape "${WATCHDOG_REPO_SHA:-}")
WATCHDOG_LAST_REMOTE_PHASE=$(shell_escape "${WATCHDOG_LAST_REMOTE_PHASE:-}")
WATCHDOG_LAST_FAILURE_SUMMARY=$(shell_escape "${WATCHDOG_LAST_FAILURE_SUMMARY:-}")
WATCHDOG_RELEASE_TAG=$(shell_escape "${WATCHDOG_RELEASE_TAG:-}")
WATCHDOG_LAST_STATUS=$(shell_escape "${WATCHDOG_LAST_STATUS:-}")
WATCHDOG_STARTED_AT=$(shell_escape "${WATCHDOG_STARTED_AT:-}")
WATCHDOG_STARTED_AT_EPOCH=$(shell_escape "${WATCHDOG_STARTED_AT_EPOCH:-}")
WATCHDOG_LAST_CHECK_AT=$(shell_escape "${WATCHDOG_LAST_CHECK_AT:-}")
WATCHDOG_REPAIR_COUNT=$(shell_escape "${WATCHDOG_REPAIR_COUNT:-0}")
WATCHDOG_LAST_CYCLE_ID=$(shell_escape "${WATCHDOG_LAST_CYCLE_ID:-}")
WATCHDOG_LOCK_SKIP_COUNT=$(shell_escape "${WATCHDOG_LOCK_SKIP_COUNT:-0}")
WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH=$(shell_escape "${WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH:-}")
WATCHDOG_PREV_FAILURE_SUMMARY=$(shell_escape "${WATCHDOG_PREV_FAILURE_SUMMARY:-}")
WATCHDOG_SAME_FAILURE_COUNT=$(shell_escape "${WATCHDOG_SAME_FAILURE_COUNT:-0}")
WATCHDOG_BUILD_PROGRESS=$(shell_escape "${WATCHDOG_BUILD_PROGRESS:-}")
EOF
}

state_clear() {
    rm -f "${STATE_FILE}" "${PROMPT_FILE}"
    WATCHDOG_FLOW_ID=""
    WATCHDOG_PHASE="idle"
    WATCHDOG_SERVER_ID=""
    WATCHDOG_SERVER_IP=""
    WATCHDOG_SERVER_NAME=""
    WATCHDOG_REPO_SHA=""
    WATCHDOG_LAST_REMOTE_PHASE=""
    WATCHDOG_LAST_FAILURE_SUMMARY=""
    WATCHDOG_RELEASE_TAG=""
    WATCHDOG_LAST_STATUS=""
    WATCHDOG_STARTED_AT=""
    WATCHDOG_STARTED_AT_EPOCH=""
    WATCHDOG_LAST_CHECK_AT=""
    WATCHDOG_REPAIR_COUNT="0"
    WATCHDOG_LAST_CYCLE_ID=""
    WATCHDOG_LOCK_SKIP_COUNT="0"
    WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH=""
    WATCHDOG_PREV_FAILURE_SUMMARY=""
    WATCHDOG_SAME_FAILURE_COUNT="0"
    WATCHDOG_BUILD_PROGRESS=""
    state_write
}

write_cycle_snapshot() {
    local cycle_id snapshot_file remote_tail
    ensure_state_dir
    cycle_id="$(date -u +%Y%m%dT%H%M%SZ)"
    WATCHDOG_LAST_CYCLE_ID="${cycle_id}"
    state_write
    snapshot_file="${CHECKS_DIR}/${cycle_id}.log"
    {
        printf 'timestamp=%s\n' "${cycle_id}"
        printf 'flow_id=%s\n' "${WATCHDOG_FLOW_ID:-}"
        printf 'phase=%s\n' "${WATCHDOG_PHASE:-}"
        printf 'status=%s\n' "${WATCHDOG_LAST_STATUS:-}"
        printf 'server_id=%s\n' "${WATCHDOG_SERVER_ID:-}"
        printf 'server_name=%s\n' "${WATCHDOG_SERVER_NAME:-}"
        printf 'server_ip=%s\n' "${WATCHDOG_SERVER_IP:-}"
        printf 'repo_sha=%s\n' "${WATCHDOG_REPO_SHA:-}"
        printf 'remote_phase=%s\n' "${WATCHDOG_LAST_REMOTE_PHASE:-}"
        printf 'failure_summary=%s\n' "${WATCHDOG_LAST_FAILURE_SUMMARY:-}"
        printf 'repair_count=%s\n' "${WATCHDOG_REPAIR_COUNT:-0}"
        printf 'release_tag=%s\n' "${WATCHDOG_RELEASE_TAG:-}"
        printf 'last_check_at=%s\n' "${WATCHDOG_LAST_CHECK_AT:-}"
        printf 'lock_skip_count=%s\n' "${WATCHDOG_LOCK_SKIP_COUNT:-0}"
        if [ -n "${WATCHDOG_SERVER_IP:-}" ]; then
            printf '\n[remote tail]\n'
            remote_tail="$(remote_tail 80 || true)"
            printf '%s\n' "${remote_tail}"
        fi
    } > "${snapshot_file}"
}

record_lock_skip() {
    local now_epoch lock_started_epoch="" lock_age_minutes=""
    now_epoch="$(date -u +%s)"
    state_load
    WATCHDOG_LOCK_SKIP_COUNT="$(( ${WATCHDOG_LOCK_SKIP_COUNT:-0} + 1 ))"
    if [ -z "${WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH:-}" ]; then
        WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH="${now_epoch}"
    fi
    if [ -f "${LOCK_META_FILE}" ]; then
        # shellcheck disable=SC1090
        . "${LOCK_META_FILE}"
        if [ -n "${LOCK_ACQUIRED_AT_EPOCH:-}" ]; then
            lock_age_minutes="$(( (now_epoch - LOCK_ACQUIRED_AT_EPOCH) / 60 ))"
        fi
    fi
    WATCHDOG_LAST_STATUS="watchdog cycle skipped because another cycle is still running"
    state_write
    if [ -n "${lock_age_minutes}" ] && [ "${lock_age_minutes}" -ge "${WATCHDOG_LOCK_WARN_MINUTES}" ] && [ "${WATCHDOG_LOCK_SKIP_COUNT}" -ge "${WATCHDOG_LOCK_WARN_SKIPS}" ]; then
        audit_log "lock still held after ${WATCHDOG_LOCK_SKIP_COUNT} skipped cycles (~${lock_age_minutes} minutes); investigate stuck watchdog run"
        log "Another watchdog cycle is still running; lock age is ~${lock_age_minutes} minutes across ${WATCHDOG_LOCK_SKIP_COUNT} skips."
    else
        audit_log "skipped cycle because another watchdog run is active"
        if [ -n "${lock_age_minutes}" ]; then
            log "Another watchdog cycle is already running (~${lock_age_minutes} minutes old lock)."
        else
            log "Another watchdog cycle is already running."
        fi
    fi
}

acquire_lock() {
    ensure_state_dir
    if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
        record_lock_skip
        exit 0
    fi
    cat > "${LOCK_META_FILE}" <<EOF
LOCK_PID="$$"
LOCK_ACQUIRED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOCK_ACQUIRED_AT_EPOCH="$(date -u +%s)"
EOF
    trap 'rm -rf "${LOCK_DIR}"' EXIT
}

reset_lock_skip_tracking() {
    if [ "${WATCHDOG_LOCK_SKIP_COUNT:-0}" != "0" ] || [ -n "${WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH:-}" ]; then
        WATCHDOG_LOCK_SKIP_COUNT="0"
        WATCHDOG_LOCK_FIRST_SEEN_AT_EPOCH=""
        state_write
    fi
}

load_env_from_zshrc() {
    local token_line token_value
    if [ ! -f "$HOME/.zshrc" ]; then
        return 0
    fi

    if [ -z "${HETZNER_API}" ]; then
        token_line="$(grep '^export HETZNER_API_TOKEN=' "$HOME/.zshrc" | tail -n1 || true)"
        token_value="${token_line#export HETZNER_API_TOKEN=}"
        token_value="${token_value%\"}"
        token_value="${token_value#\"}"
        token_value="${token_value%\'}"
        token_value="${token_value#\'}"
        if [ -n "${token_value}" ] && [ "${token_value}" != "${token_line}" ]; then
            HETZNER_API="${token_value}"
        fi
    fi

    if [ -z "${GH_TOKEN}" ]; then
        token_line="$(grep '^export GH_TOKEN=' "$HOME/.zshrc" | tail -n1 || true)"
        token_value="${token_line#export GH_TOKEN=}"
        token_value="${token_value%\"}"
        token_value="${token_value#\"}"
        token_value="${token_value%\'}"
        token_value="${token_value#\'}"
        if [ -n "${token_value}" ] && [ "${token_value}" != "${token_line}" ]; then
            GH_TOKEN="${token_value}"
        fi
    fi
}

require_credentials() {
    load_env_from_zshrc
    if [ -z "${GH_TOKEN}" ] && command -v gh >/dev/null 2>&1; then
        GH_TOKEN="$(gh auth token 2>/dev/null || true)"
    fi

    [ -n "${HETZNER_API}" ] || { log "ERROR: HETZNER_API_TOKEN is missing."; exit 1; }
    [ -n "${GH_TOKEN}" ] || { log "ERROR: GitHub auth is missing."; exit 1; }
    command -v ssh >/dev/null 2>&1 || { log "ERROR: ssh is required."; exit 1; }
    command -v scp >/dev/null 2>&1 || { log "ERROR: scp is required."; exit 1; }
    command -v curl >/dev/null 2>&1 || { log "ERROR: curl is required."; exit 1; }
    command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 is required."; exit 1; }
    command -v grep >/dev/null 2>&1 || { log "ERROR: grep is required."; exit 1; }

    if [ "${WATCHDOG_RUN_CLAUDE}" = "1" ]; then
        if [ -x "${WATCHDOG_CLAUDE_BIN}" ]; then
            :
        elif command -v claude >/dev/null 2>&1; then
            WATCHDOG_CLAUDE_BIN="$(command -v claude)"
        else
            log "ERROR: claude CLI is required when WATCHDOG_RUN_CLAUDE=1."
            exit 1
        fi
    fi
}

git_preflight() {
    local branch status_output local_sha remote_sha
    branch="${WATCHDOG_REPO_REF}"
    status_output="$(git -C "${PROJECT_DIR}" status --porcelain --untracked-files=all | grep -vE '^\?\? \.omc(/|$)' || true)"
    if [ -n "${status_output}" ]; then
        WATCHDOG_LAST_STATUS="repo has uncommitted changes"
        state_write
        audit_log "preflight failed: repo has uncommitted changes"
        return 1
    fi

    git -C "${PROJECT_DIR}" fetch origin "${branch}" >/dev/null 2>&1
    local_sha="$(git -C "${PROJECT_DIR}" rev-parse HEAD)"
    remote_sha="$(git -C "${PROJECT_DIR}" rev-parse "origin/${branch}")"
    if [ "${local_sha}" != "${remote_sha}" ]; then
        WATCHDOG_LAST_STATUS="repo is not synced to origin/${branch}"
        state_write
        audit_log "preflight failed: repo is not synced to origin/${branch}"
        return 1
    fi

    if ! bash "${PROJECT_DIR}/scripts/preflight-fp-chromium-build.sh" repo "${PROJECT_DIR}" >/dev/null; then
        WATCHDOG_LAST_STATUS="repo preflight gauntlet failed"
        state_write
        audit_log "preflight failed: repo gauntlet failed"
        return 1
    fi

    WATCHDOG_REPO_SHA="${local_sha}"
    state_write
    return 0
}

hetzner_api() {
    local method="$1"
    local endpoint="$2"
    shift 2
    curl -sS -X "${method}" \
        -H "Authorization: Bearer ${HETZNER_API}" \
        -H "Content-Type: application/json" \
        "https://api.hetzner.cloud/v1${endpoint}" "$@"
}

find_ssh_key_id() {
    local response key_id
    response="$(hetzner_api GET "/ssh_keys?name=${WATCHDOG_SSH_KEY_NAME}")"
    key_id="$(printf '%s' "${response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ssh_keys"][0]["id"])' 2>/dev/null || true)"
    [ -n "${key_id}" ] || { log "ERROR: Hetzner SSH key '${WATCHDOG_SSH_KEY_NAME}' not found."; exit 1; }
    printf '%s\n' "${key_id}"
}

create_server() {
    local ssh_key_id create_response
    ssh_key_id="$(find_ssh_key_id)"
    WATCHDOG_SERVER_NAME="${WATCHDOG_SERVER_NAME_PREFIX}-$(date +%Y%m%d-%H%M%S)"
    create_response="$(hetzner_api POST "/servers" -d "{
      \"name\": \"${WATCHDOG_SERVER_NAME}\",
      \"server_type\": \"${WATCHDOG_SERVER_TYPE}\",
      \"image\": \"${WATCHDOG_SERVER_IMAGE}\",
      \"location\": \"${WATCHDOG_SERVER_LOCATION}\",
      \"ssh_keys\": [${ssh_key_id}],
      \"start_after_create\": true
    }")"

    WATCHDOG_SERVER_ID="$(printf '%s' "${create_response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["server"]["id"])' 2>/dev/null || true)"
    WATCHDOG_SERVER_IP="$(printf '%s' "${create_response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["server"]["public_net"]["ipv4"]["ip"])' 2>/dev/null || true)"
    [ -n "${WATCHDOG_SERVER_ID}" ] && [ -n "${WATCHDOG_SERVER_IP}" ] || { log "ERROR: failed to create Hetzner server."; exit 1; }
    WATCHDOG_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    WATCHDOG_STARTED_AT_EPOCH="$(date -u +%s)"
    WATCHDOG_FLOW_ID="${WATCHDOG_FLOW_ID:-flow-$(date -u +%Y%m%dT%H%M%SZ)}"
    WATCHDOG_PHASE="provisioning"
    WATCHDOG_LAST_STATUS="created Hetzner server"
    state_write
    audit_log "created Hetzner server"
    log "Server ready: ${WATCHDOG_SERVER_ID} @ ${WATCHDOG_SERVER_IP}"
}

cleanup_server() {
    if [ -z "${WATCHDOG_SERVER_ID:-}" ]; then
        return 0
    fi
    log "Destroying Hetzner server ${WATCHDOG_SERVER_ID} (${WATCHDOG_SERVER_NAME})..."
    hetzner_api DELETE "/servers/${WATCHDOG_SERVER_ID}" >/dev/null 2>&1 || true
    audit_log "destroyed Hetzner server"
}

server_exists_api() {
    if [ -z "${WATCHDOG_SERVER_ID:-}" ]; then
        return 1
    fi
    local response
    response="$(hetzner_api GET "/servers/${WATCHDOG_SERVER_ID}" 2>/dev/null || true)"
    printf '%s' "${response}" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("server") else 1)' >/dev/null 2>&1
}

server_reachable_ssh() {
    if [ -z "${WATCHDOG_SERVER_IP:-}" ]; then
        return 1
    fi
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" "echo ready" >/dev/null 2>&1
}

confirm_server_available() {
    if server_exists_api; then
        return 0
    fi
    if server_reachable_ssh; then
        audit_log "Hetzner API missed tracked server but SSH still works; preserving current VM"
        return 0
    fi
    sleep 5
    if server_exists_api || server_reachable_ssh; then
        audit_log "tracked server check recovered after retry"
        return 0
    fi
    return 1
}

wait_for_ssh() {
    local attempt
    for attempt in $(seq 1 60); do
        if server_reachable_ssh; then
            return 0
        fi
        sleep 5
    done
    return 1
}

remote_run() {
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" bash -s -- "$@" <<'REMOTE'
set -euo pipefail
"$@"
REMOTE
}

install_remote_support() {
    local token_file
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" "mkdir -p /root/abp-watchdog"
    scp "${SSH_OPTS[@]}" "${PROJECT_DIR}/scripts/watchdog-remote.sh" "root@${WATCHDOG_SERVER_IP}:/root/abp-watchdog/watchdog-remote.sh" >/dev/null
    ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" "chmod +x /root/abp-watchdog/watchdog-remote.sh"

    token_file="$(mktemp)"
    chmod 600 "${token_file}"
    printf '%s' "${GH_TOKEN}" > "${token_file}"
    scp "${SSH_OPTS[@]}" "${token_file}" "root@${WATCHDOG_SERVER_IP}:/root/.gh_token" >/dev/null
    rm -f "${token_file}"
}

remote_status() {
    local tmp
    tmp="$(mktemp)"
    if ! remote_run /root/abp-watchdog/watchdog-remote.sh status > "${tmp}" 2>/dev/null; then
        rm -f "${tmp}"
        return 1
    fi
    # shellcheck disable=SC1090
    . "${tmp}"
    rm -f "${tmp}"
    return 0
}

remote_tail() {
    remote_run /root/abp-watchdog/watchdog-remote.sh tail "${1:-80}" 2>/dev/null || true
}

save_remote_log() {
    if [ -z "${WATCHDOG_SERVER_IP:-}" ]; then
        return 0
    fi
    local target ts
    ensure_state_dir
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    target="${STATE_DIR}/remote-build-${ts}.log"
    remote_run /root/abp-watchdog/watchdog-remote.sh tail 4000 > "${target}" 2>/dev/null || true
    [ -s "${target}" ] || rm -f "${target}"
}

remote_start() {
    install_remote_support
    remote_run /root/abp-watchdog/watchdog-remote.sh start \
        "${WATCHDOG_REPO_SHA}" \
        "${WATCHDOG_FP_CHROMIUM_TAG}" \
        "${WATCHDOG_ABP_BRANCH}" \
        "${WATCHDOG_REPO_URL}" \
        "${WATCHDOG_REPO_REF}" >/dev/null
    WATCHDOG_PHASE="building"
    WATCHDOG_LAST_STATUS="remote build running"
    WATCHDOG_LAST_REMOTE_PHASE="building"
    state_write
}

remote_restart() {
    install_remote_support
    remote_run /root/abp-watchdog/watchdog-remote.sh restart \
        "${WATCHDOG_REPO_SHA}" \
        "${WATCHDOG_FP_CHROMIUM_TAG}" \
        "${WATCHDOG_ABP_BRANCH}" \
        "${WATCHDOG_REPO_URL}" \
        "${WATCHDOG_REPO_REF}" >/dev/null
    WATCHDOG_PHASE="building"
    WATCHDOG_LAST_STATUS="remote build restarted"
    WATCHDOG_LAST_REMOTE_PHASE="building"
    state_write
}

extract_remote_errors() {
    # Extract actual error lines from the remote build log, not just tail spam
    local errors
    errors="$(ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" \
        "grep -n -E 'FAILED:|fatal:|^ERROR|error:.*failed|No such file|not found|undefined reference' /root/abp-watchdog/build.log 2>/dev/null | tail -20" 2>/dev/null || true)"
    printf '%s\n' "${errors}"
}

extract_build_step() {
    # Extract the last build step marker (==> [N/9])
    local step
    step="$(ssh "${SSH_OPTS[@]}" "root@${WATCHDOG_SERVER_IP}" \
        "grep -oP '==> \[.*/.*\].*' /root/abp-watchdog/build.log 2>/dev/null | tail -1" 2>/dev/null || true)"
    printf '%s\n' "${step}"
}

render_prompt() {
    local log_excerpt error_lines build_step
    log_excerpt="$(remote_tail 80 | sed 's/^/  /' || true)"
    error_lines="$(extract_remote_errors | sed 's/^/  /' || true)"
    build_step="$(extract_build_step || true)"
    cat > "${PROMPT_FILE}" <<EOF
# ABP Watchdog Repair Prompt

## Goal
Fix the repo-side cause of the current Hetzner build failure, commit, and push.

## Current state
- Flow: ${WATCHDOG_FLOW_ID:-unknown}
- Commit on VM: ${WATCHDOG_REPO_SHA:-unknown}
- Server IP: ${WATCHDOG_SERVER_IP:-none}
- Failed build step: ${build_step:-unknown}
- Last failure: ${WATCHDOG_LAST_FAILURE_SUMMARY:-unknown}
- Repair attempt: ${WATCHDOG_REPAIR_COUNT:-0} of ${WATCHDOG_MAX_REPAIRS}
- Same failure repeated: ${WATCHDOG_SAME_FAILURE_COUNT:-0} times

## Error lines from build log
${error_lines:-  (no structured errors extracted)}

## Recent build log tail (last 80 lines)
${log_excerpt}

## What you MUST do
1. Read the error lines above to identify the root cause.
2. Fix ONLY the files that caused the build to fail.
3. git add, commit, and push your fix.
4. The watchdog will automatically restart the build on the existing VM.

## What you MUST NOT do
- Do NOT create, destroy, or SSH into Hetzner VMs.
- Do NOT edit watchdog state files under ~/.cache/abp-watchdog/.
- Do NOT edit the Dockerfile or deploy workflow (the watchdog handles that).
- Do NOT make unrelated improvements or refactors.
- Do NOT edit files outside of: scripts/, patches/, CLAUDE.md

## Files you may edit
- scripts/build-on-fp-chromium.sh (build configuration, GN args, patches)
- scripts/apply-stealth-extra-edits.sh (stealth patches)
- scripts/apply-feature-edits.sh (feature patches)
- scripts/verify-abp-overlay-contract.sh (overlay validation)
- scripts/ensure-rust-toolchain.sh, scripts/ensure-node-esbuild.sh (toolchain)
- scripts/preflight-fp-chromium-build.sh (preflight checks)
- scripts/patch_flags_state.py (GN flags fix)
- patches/stealth-extra/* (patch files)

## Key context
- Build is fingerprint-chromium ${WATCHDOG_FP_CHROMIUM_TAG} + ABP overlay
- Build runs on Ubuntu 22.04 with use_sysroot=false
- is_component_build=false, is_official_build=true, is_debug=false
- NaCl is removed in Chromium 142 (enable_nacl is not a valid arg)
- The build script is scripts/build-on-fp-chromium.sh
- ABP protocol source is from github.com/theredsix/agent-browser-protocol (branch: dev)

## Expected output format
- Root cause: <one sentence>
- Files changed: <list>
- Commit SHA: <sha after push>
EOF
    cat "${PROMPT_FILE}"
}

run_claude_repair_cycle() {
    if [ "${WATCHDOG_RUN_CLAUDE}" != "1" ]; then
        return 0
    fi
    render_prompt >/dev/null
    local prompt_text
    prompt_text="$(cat "${PROMPT_FILE}")"
    audit_log "starting claude repair cycle (model: ${WATCHDOG_CLAUDE_REPAIR_MODEL})"
    if command -v timeout >/dev/null 2>&1; then
        timeout "${WATCHDOG_CLAUDE_TIMEOUT_SECONDS}" \
            "${WATCHDOG_CLAUDE_BIN}" -p "${prompt_text}" \
            --dangerously-skip-permissions \
            --output-format text \
            --model "${WATCHDOG_CLAUDE_REPAIR_MODEL}" \
            >> "${LOG_FILE}" 2>&1 || true
    else
        "${WATCHDOG_CLAUDE_BIN}" -p "${prompt_text}" \
            --dangerously-skip-permissions \
            --output-format text \
            --model "${WATCHDOG_CLAUDE_REPAIR_MODEL}" \
            >> "${LOG_FILE}" 2>&1 || true
    fi
    audit_log "finished claude repair cycle"
}

mark_failed_and_cleanup() {
    WATCHDOG_PHASE="aborted"
    WATCHDOG_LAST_STATUS="$1"
    state_write
    audit_log "$1"
    save_remote_log || true
    cleanup_server
    uninstall_cron >/dev/null 2>&1 || true
    reset_runtime_state_keep_summary
}

reset_runtime_state_keep_summary() {
    WATCHDOG_SERVER_ID=""
    WATCHDOG_SERVER_IP=""
    WATCHDOG_SERVER_NAME=""
    WATCHDOG_LAST_REMOTE_PHASE=""
    WATCHDOG_RELEASE_TAG=""
    state_write
}

update_dockerfile_version() {
    local tag="$1"
    if [ -z "${tag}" ]; then
        audit_log "no release tag to update Dockerfile with"
        return 1
    fi
    local dockerfile="${PROJECT_DIR}/Dockerfile"
    if ! grep -q "ARG ABP_STEALTH_VERSION=" "${dockerfile}"; then
        audit_log "Dockerfile missing ABP_STEALTH_VERSION arg"
        return 1
    fi
    sed -i "s|^ARG ABP_STEALTH_VERSION=.*|ARG ABP_STEALTH_VERSION=${tag}|" "${dockerfile}"
    git -C "${PROJECT_DIR}" add Dockerfile
    git -C "${PROJECT_DIR}" commit -m "Update ABP_STEALTH_VERSION to ${tag}"
    git -C "${PROJECT_DIR}" push origin "${WATCHDOG_REPO_REF}"
    audit_log "updated Dockerfile to ${tag} and pushed"
}

trigger_deploy() {
    audit_log "triggering deploy workflow"
    gh workflow run deploy.yml --repo nmajor/abp-unikraft --ref "${WATCHDOG_REPO_REF}" 2>&1 || {
        audit_log "failed to trigger deploy workflow"
        return 1
    }
    # Wait for the run to appear then poll for completion
    sleep 10
    local run_id status elapsed
    run_id="$(gh run list --repo nmajor/abp-unikraft --workflow=deploy.yml --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
    if [ -z "${run_id}" ]; then
        audit_log "could not find deploy run"
        return 1
    fi
    audit_log "deploy run ${run_id} started"
    elapsed=0
    while [ "${elapsed}" -lt "${WATCHDOG_DEPLOY_TIMEOUT_SECONDS}" ]; do
        status="$(gh run view "${run_id}" --repo nmajor/abp-unikraft --json status,conclusion --jq '.status + ":" + (.conclusion // "")' 2>/dev/null || true)"
        case "${status}" in
            completed:success)
                audit_log "deploy run ${run_id} succeeded"
                return 0
                ;;
            completed:*)
                audit_log "deploy run ${run_id} failed: ${status}"
                return 1
                ;;
        esac
        sleep 30
        elapsed="$(( elapsed + 30 ))"
    done
    audit_log "deploy run ${run_id} timed out after ${WATCHDOG_DEPLOY_TIMEOUT_SECONDS}s"
    return 1
}

run_smoke_test() {
    # Resolve the KraftCloud FQDN for the instance
    local kraft_token fqdn
    kraft_token="${WATCHDOG_KRAFT_TOKEN:-${UKC_TOKEN:-}}"
    if [ -z "${kraft_token}" ]; then
        # Try loading from .zshrc
        local token_line
        token_line="$(grep '^export UKC_TOKEN=' "$HOME/.zshrc" 2>/dev/null | tail -n1 || true)"
        kraft_token="${token_line#export UKC_TOKEN=}"
        kraft_token="${kraft_token%\"}"
        kraft_token="${kraft_token#\"}"
    fi

    # Get the FQDN from kraft
    if [ -n "${kraft_token}" ] && command -v kraft >/dev/null 2>&1; then
        fqdn="$(kraft cloud --token "${kraft_token}" --metro fra instance get abp-unikraft 2>/dev/null \
            | grep 'fqdn:' | awk '{print $2}' || true)"
    fi

    if [ -z "${fqdn}" ]; then
        # Fallback: try the known pattern
        audit_log "could not resolve FQDN, skipping smoke test"
        return 1
    fi

    local url="https://${fqdn}"
    audit_log "running smoke test against ${url}"

    if [ -x "${PROJECT_DIR}/scripts/test-deployment.sh" ]; then
        if "${PROJECT_DIR}/scripts/test-deployment.sh" "${url}" >> "${LOG_FILE}" 2>&1; then
            audit_log "smoke test passed"
            return 0
        else
            audit_log "smoke test failed"
            return 1
        fi
    fi

    # Minimal fallback: just check health endpoint
    local http_code
    http_code="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' "${url}/json/version" 2>/dev/null || true)"
    if [ "${http_code}" = "200" ]; then
        audit_log "health check passed (HTTP ${http_code})"
        return 0
    fi
    audit_log "health check failed (HTTP ${http_code:-timeout})"
    return 1
}

handle_completed_flow() {
    WATCHDOG_LAST_REMOTE_PHASE="completed"
    WATCHDOG_RELEASE_TAG="${REMOTE_RELEASE_TAG:-}"
    state_write
    audit_log "build completed with release ${WATCHDOG_RELEASE_TAG:-unknown}"
    write_cycle_snapshot

    # Clean up the Hetzner build VM first (stop the cost clock)
    cleanup_server

    # Post-build: update Dockerfile and deploy
    if [ "${WATCHDOG_AUTO_DEPLOY}" = "1" ] && [ -n "${WATCHDOG_RELEASE_TAG:-}" ]; then
        WATCHDOG_PHASE="deploying"
        WATCHDOG_LAST_STATUS="updating Dockerfile and deploying"
        state_write

        if update_dockerfile_version "${WATCHDOG_RELEASE_TAG}"; then
            if trigger_deploy; then
                WATCHDOG_LAST_STATUS="deploy succeeded"
                state_write
                audit_log "deploy succeeded"

                # Post-deploy: smoke test
                if [ "${WATCHDOG_AUTO_SMOKE_TEST}" = "1" ]; then
                    WATCHDOG_PHASE="smoke_testing"
                    WATCHDOG_LAST_STATUS="running smoke test"
                    state_write
                    # Give KraftCloud a moment to start the instance
                    sleep 15
                    if run_smoke_test; then
                        WATCHDOG_PHASE="fully_completed"
                        WATCHDOG_LAST_STATUS="build + deploy + smoke test all passed"
                    else
                        WATCHDOG_PHASE="completed_deploy_untested"
                        WATCHDOG_LAST_STATUS="deploy succeeded but smoke test failed"
                    fi
                else
                    WATCHDOG_PHASE="completed_deployed"
                    WATCHDOG_LAST_STATUS="build and deploy succeeded (smoke test skipped)"
                fi
            else
                WATCHDOG_PHASE="completed_deploy_failed"
                WATCHDOG_LAST_STATUS="build succeeded but deploy failed"
            fi
        else
            WATCHDOG_PHASE="completed"
            WATCHDOG_LAST_STATUS="build succeeded but Dockerfile update failed"
        fi
    else
        WATCHDOG_PHASE="completed"
        WATCHDOG_LAST_STATUS="build completed (auto-deploy disabled or no release tag)"
    fi

    state_write
    audit_log "${WATCHDOG_LAST_STATUS}"
    uninstall_cron >/dev/null 2>&1 || true
    reset_runtime_state_keep_summary
}

handle_repair_pending() {
    local current_failure="${REMOTE_FAILURE_SUMMARY:-build failed}"
    WATCHDOG_PHASE="repair_pending"
    WATCHDOG_LAST_REMOTE_PHASE="${REMOTE_PHASE:-failed}"
    WATCHDOG_LAST_FAILURE_SUMMARY="${current_failure}"
    WATCHDOG_LAST_STATUS="awaiting repo fix/push before restart on existing VM"
    WATCHDOG_REPAIR_COUNT="$(( ${WATCHDOG_REPAIR_COUNT:-0} + 1 ))"

    # Guardrail 1: cap total repair attempts
    if [ "${WATCHDOG_REPAIR_COUNT}" -gt "${WATCHDOG_MAX_REPAIRS}" ]; then
        mark_failed_and_cleanup "exceeded max repair attempts (${WATCHDOG_MAX_REPAIRS})"
        return 1
    fi

    # Guardrail 2: detect stuck repairs (same error repeating)
    if [ "${current_failure}" = "${WATCHDOG_PREV_FAILURE_SUMMARY:-}" ]; then
        WATCHDOG_SAME_FAILURE_COUNT="$(( ${WATCHDOG_SAME_FAILURE_COUNT:-0} + 1 ))"
    else
        WATCHDOG_SAME_FAILURE_COUNT="1"
        WATCHDOG_PREV_FAILURE_SUMMARY="${current_failure}"
    fi
    if [ "${WATCHDOG_SAME_FAILURE_COUNT}" -ge "${WATCHDOG_MAX_SAME_FAILURE}" ]; then
        mark_failed_and_cleanup "same failure repeated ${WATCHDOG_SAME_FAILURE_COUNT} times: ${current_failure}"
        return 1
    fi

    state_write
    audit_log "repair pending after remote failure (attempt ${WATCHDOG_REPAIR_COUNT}/${WATCHDOG_MAX_REPAIRS})"
    save_remote_log || true

    if git_preflight && [ "${WATCHDOG_REPO_SHA}" != "${REMOTE_COMMIT_SHA:-}" ]; then
        audit_log "restarting build on existing VM with pushed fix ${WATCHDOG_REPO_SHA}"
        remote_restart
        return 0
    fi

    write_cycle_snapshot
    run_claude_repair_cycle
}

start_new_flow() {
    git_preflight || { write_cycle_snapshot; return 0; }
    create_server
    WATCHDOG_PHASE="bootstrapping"
    WATCHDOG_LAST_STATUS="waiting for SSH"
    state_write
    audit_log "waiting for SSH"
    wait_for_ssh || { mark_failed_and_cleanup "failed to reach new server by SSH"; return 1; }
    remote_start
    write_cycle_snapshot
}

poll_remote_flow() {
    if ! confirm_server_available; then
        mark_failed_and_cleanup "tracked Hetzner server disappeared"
        return 1
    fi

    wait_for_ssh || { WATCHDOG_LAST_STATUS="server is up but SSH is not ready"; state_write; write_cycle_snapshot; return 0; }
    install_remote_support

    if ! remote_status; then
        WATCHDOG_LAST_STATUS="remote supervisor unavailable"
        state_write
        write_cycle_snapshot
        return 0
    fi

    WATCHDOG_LAST_REMOTE_PHASE="${REMOTE_PHASE:-unknown}"
    case "${REMOTE_PHASE:-idle}" in
        building)
            WATCHDOG_PHASE="building"
            WATCHDOG_REPO_SHA="${REMOTE_COMMIT_SHA:-${WATCHDOG_REPO_SHA}}"
            # Extract build progress for status display
            local tail_out progress_info
            tail_out="$(remote_tail 10 2>/dev/null || true)"
            progress_info="$(extract_build_progress_from_tail "${tail_out}")"
            WATCHDOG_BUILD_PROGRESS="${progress_info:-compiling}"
            WATCHDOG_LAST_STATUS="remote build running ${WATCHDOG_BUILD_PROGRESS}"
            state_write
            write_cycle_snapshot
            ;;
        completed)
            WATCHDOG_REPO_SHA="${REMOTE_COMMIT_SHA:-${WATCHDOG_REPO_SHA}}"
            handle_completed_flow
            ;;
        failed|stopped)
            WATCHDOG_REPO_SHA="${REMOTE_COMMIT_SHA:-${WATCHDOG_REPO_SHA}}"
            handle_repair_pending
            ;;
        idle)
            if [ "${WATCHDOG_PHASE:-idle}" = "repair_pending" ]; then
                handle_repair_pending
            else
                WATCHDOG_LAST_STATUS="remote supervisor idle"
                state_write
                write_cycle_snapshot
            fi
            ;;
        *)
            WATCHDOG_LAST_STATUS="unexpected remote phase: ${REMOTE_PHASE:-unknown}"
            state_write
            write_cycle_snapshot
            ;;
    esac
}

start_cycle() {
    ensure_state_dir
    acquire_lock
    state_load
    require_credentials
    reset_lock_skip_tracking

    WATCHDOG_LAST_CHECK_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    audit_log "cycle started"

    if [ -n "${WATCHDOG_STARTED_AT_EPOCH:-}" ]; then
        local now_epoch elapsed_seconds timeout_seconds
        now_epoch="$(date -u +%s)"
        elapsed_seconds="$(( now_epoch - WATCHDOG_STARTED_AT_EPOCH ))"
        timeout_seconds="$(( WATCHDOG_FLOW_TIMEOUT_HOURS * 3600 ))"
        if [ "${elapsed_seconds}" -gt "${timeout_seconds}" ]; then
            mark_failed_and_cleanup "watchdog flow exceeded ${WATCHDOG_FLOW_TIMEOUT_HOURS}h"
            return 1
        fi
    fi

    if [ -z "${WATCHDOG_SERVER_ID:-}" ]; then
        start_new_flow
        return 0
    fi

    poll_remote_flow
}

extract_build_progress_from_tail() {
    # Parse ninja [X/Y] progress from recent log output
    local tail_output="$1"
    local progress
    progress="$(printf '%s' "${tail_output}" | grep -oP '\[\d+/\d+\]' | tail -1 || true)"
    if [ -n "${progress}" ]; then
        printf '%s' "${progress}"
        return
    fi
    # Fallback: last ==> step marker
    progress="$(printf '%s' "${tail_output}" | grep -oP '==> \[.*\].*' | tail -1 || true)"
    printf '%s' "${progress}"
}

status() {
    state_load
    local progress_line=""
    if [ -n "${WATCHDOG_SERVER_IP:-}" ] && [ "${WATCHDOG_PHASE:-}" = "building" ]; then
        local tail_out
        tail_out="$(remote_tail 20 2>/dev/null || true)"
        progress_line="$(extract_build_progress_from_tail "${tail_out}")"
    fi
    cat <<EOF
Flow: ${WATCHDOG_FLOW_ID:-none}
Phase: ${WATCHDOG_PHASE:-idle}
Server: ${WATCHDOG_SERVER_NAME:-none}
Server ID: ${WATCHDOG_SERVER_ID:-none}
Server IP: ${WATCHDOG_SERVER_IP:-none}
Repo SHA: ${WATCHDOG_REPO_SHA:-none}
Remote phase: ${WATCHDOG_LAST_REMOTE_PHASE:-none}
Last failure: ${WATCHDOG_LAST_FAILURE_SUMMARY:-none}
Repair count: ${WATCHDOG_REPAIR_COUNT:-0}/${WATCHDOG_MAX_REPAIRS}
Same failure streak: ${WATCHDOG_SAME_FAILURE_COUNT:-0}/${WATCHDOG_MAX_SAME_FAILURE}
Release: ${WATCHDOG_RELEASE_TAG:-none}
Build progress: ${progress_line:-n/a}
Last check: ${WATCHDOG_LAST_CHECK_AT:-none}
EOF
    if [ -n "${WATCHDOG_SERVER_IP:-}" ]; then
        remote_tail 40 || true
    fi
}

cleanup_command() {
    state_load
    cleanup_server
    state_clear
    uninstall_cron >/dev/null 2>&1 || true
    audit_log "manual cleanup invoked"
}

uninstall_cron() {
    ensure_state_dir
    local current_crontab tmp_crontab
    current_crontab="$(crontab -l 2>/dev/null || true)"
    tmp_crontab="$(mktemp)"
    printf '%s\n' "${current_crontab}" | grep -v 'ABP watchdog deployment' > "${tmp_crontab}" || true
    crontab "${tmp_crontab}"
    rm -f "${tmp_crontab}"
    audit_log "removed watchdog cron entry"
}

install_cron() {
    ensure_state_dir
    local repo_root current_crontab tmp_crontab cron_line marker
    repo_root="${PROJECT_DIR}"
    marker="# ABP watchdog deployment"
    cron_line="*/5 * * * * cd ${repo_root} && zsh -lc 'PATH=/var/lib/asdf/installs/nodejs/24.8.0/bin:/var/lib/asdf/shims:/usr/local/bin:/usr/bin:/bin WATCHDOG_STATE_DIR=${STATE_DIR} WATCHDOG_RUN_CLAUDE=1 WATCHDOG_CLAUDE_BIN=${WATCHDOG_CLAUDE_BIN} WATCHDOG_CLAUDE_TIMEOUT_SECONDS=600 ./scripts/watchdog-hetzner.sh cycle >> ${CRON_LOG_FILE} 2>&1' ${marker}"
    current_crontab="$(crontab -l 2>/dev/null || true)"
    tmp_crontab="$(mktemp)"
    printf '%s\n' "${current_crontab}" | grep -v 'ABP watchdog deployment' > "${tmp_crontab}" || true
    printf '%s\n' "${cron_line}" >> "${tmp_crontab}"
    crontab "${tmp_crontab}"
    rm -f "${tmp_crontab}"
    audit_log "installed watchdog cron entry"
    log "Installed cron entry:"
    printf '%s\n' "${cron_line}"
}

main() {
    local cmd="${1:-cycle}"
    case "${cmd}" in
        cycle|start) start_cycle ;;
        status) status ;;
        prompt) render_prompt ;;
        cleanup) cleanup_command ;;
        install-cron) install_cron ;;
        uninstall-cron) uninstall_cron ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
